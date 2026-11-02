import Foundation
import Citadel
import NIO
import NIOConcurrencyHelpers
import NIOSSH

/// One interactive PTY channel: terminal output as a bounded pull queue,
/// typed input via `send`, resize via `setSize`.
///
/// Backpressure: the read loop inside `open()` suspends once queued
/// output passes the high-water mark, capping this layer's buffer to a
/// byte budget instead of an unbounded stream. Citadel's PTY inbound
/// API exposes no channel handle to pause NIO reads, so this queue is
/// the enforceable byte budget — and bytes are never dropped, because
/// dropped terminal output corrupts rendering.
actor ShellChannel {

    enum Event: Sendable {
        case output(Data)
        case closed(Error?)
    }

    private var writer: Citadel.TTYStdinWriter?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var task: Task<Void, Never>?

    // MARK: - Bounded output queue

    /// Events queue in arrival order; `pendingHead` makes consumption
    /// amortized O(1) instead of quadratic removeFirst churn.
    private var pending: [Event] = []
    private var pendingHead = 0
    private var pendingBytes = 0
    private var finished = false
    /// Consumers suspended on an empty queue.
    private var emptyWaiters: [CheckedContinuation<Void, Never>] = []
    /// The producer suspended on a full queue (the backpressure point).
    private var fullWaiters: [CheckedContinuation<Void, Never>] = []
    private static let highWaterBytes = 2 * 1024 * 1024
    private static let lowWaterBytes = 512 * 1024

    // MARK: - Resize state

    /// Latest size the session asked for — the *target*, updated at
    /// request time. `wireCols`/`wireRows` is what the remote actually
    /// got: it only mutates after a changeSize write completes, so a
    /// failed or in-flight resize never masquerades as applied.
    private var targetCols = 0
    private var targetRows = 0
    private var wireCols = 0
    private var wireRows = 0
    /// Monotonic request sequence — a stale resize task whose sequence
    /// was superseded skips its wire write entirely (coalescing), and a
    /// replayed size can never clobber a newer one.
    private var targetSeq = 0
    private var wireSeq = 0
    /// Single writer path: every wire changeSize chains off the previous
    /// one, so resizes reach the remote strictly in request order.
    private var resizeChain: Task<Void, Never>?
    /// A resize that failed (or predates channel open) is replayed at
    /// the next opportunity — attach, the next setSize, or before input.
    private var resizeDirty = false

    init() {}

    deinit {
        task?.cancel()
        for waiter in emptyWaiters + fullWaiters { waiter.resume() }
        readyContinuation?.resume(throwing: CancellationError())
    }

    // MARK: - Lifecycle

    func open(on client: Citadel.SSHClient, cols: Int, rows: Int) async throws {
        targetCols = max(1, cols)
        targetRows = max(1, rows)
        targetSeq += 1
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: targetCols,
            terminalRowHeight: targetRows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([.ECHO: 1])
        )

        task = Task { [weak self] in
            do {
                try await client.withPTY(request) { inbound, outbound in
                    await self?.attach(writer: outbound)
                    for try await item in inbound {
                        switch item {
                        case .stdout(let buffer), .stderr(let buffer):
                            await self?.emit(Data(buffer.readableBytesView))
                        }
                        if Task.isCancelled { return }
                    }
                }
                await self?.finish(nil)
            } catch {
                await self?.fail(error)
            }
        }

        do {
            try await withTimeout(.seconds(15)) { try await self.waitReady() }
        } catch {
            task?.cancel()
            finish(error)
            throw error
        }
        // The PTY request carries the size, but some servers ignore it
        // until the shell is live — re-assert once the channel is open.
        resizeDirty = true
        replayResize()
    }

    /// Channel-open deadline — same boxed-race as the connection's
    /// helper (a task group would await the losing child at scope
    /// exit and void the deadline).
    private func withTimeout<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let box = NIOLockedValueBox<CheckedContinuation<T, Error>?>(nil)
        let workTask = Task<T, Error> { try await work() }
        defer { workTask.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                box.withLockedValue { $0 = cont }
                Task {
                    let result = await workTask.result
                    box.withLockedValue {
                        $0?.resume(with: result)
                        $0 = nil
                    }
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    box.withLockedValue {
                        $0?.resume(throwing: CancellationError())
                        $0 = nil
                    }
                }
            }
        } onCancel: {
            box.withLockedValue {
                $0?.resume(throwing: CancellationError())
                $0 = nil
            }
            workTask.cancel()
        }
    }

    private func attach(writer: Citadel.TTYStdinWriter) {
        self.writer = writer
        readyContinuation?.resume()
        readyContinuation = nil
    }

    private func waitReady() async throws {
        try await withCheckedThrowingContinuation { cont in
            readyContinuation = cont
        }
    }

    // MARK: - Output queue

    /// Producer side — suspends while the queue holds more than the
    /// high-water mark, which stops draining the Citadel stream and
    /// lets transport-level backpressure bound total memory.
    private func emit(_ data: Data) async {
        pending.append(.output(data))
        pendingBytes += data.count
        resumeEmptyWaiters()
        while pendingBytes >= Self.highWaterBytes, !finished {
            await withCheckedContinuation { fullWaiters.append($0) }
        }
    }

    /// Consumer side — the next event in order, or nil once the channel
    /// is closed and drained. Output enqueued before a close is still
    /// delivered first: closing never truncates produced bytes.
    func nextEvent() async -> Event? {
        while true {
            if pendingHead < pending.count {
                let event = pending[pendingHead]
                pendingHead += 1
                if case .output(let data) = event {
                    pendingBytes -= data.count
                }
                if pendingHead > 64, pendingHead * 2 >= pending.count {
                    pending.removeFirst(pendingHead)
                    pendingHead = 0
                }
                if pendingBytes <= Self.lowWaterBytes {
                    resumeFullWaiters()
                }
                return event
            }
            pending.removeAll(keepingCapacity: true)
            pendingHead = 0
            if finished || Task.isCancelled { return nil }
            await withCheckedContinuation { emptyWaiters.append($0) }
        }
    }

    private func resumeEmptyWaiters() {
        let waiters = emptyWaiters
        emptyWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func resumeFullWaiters() {
        let waiters = fullWaiters
        fullWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Terminal close lands in-band after already-produced output so the
    /// consumer drains every byte before it sees the end. The writer is
    /// dead from here on — drop it so later sends and resizes can't
    /// write into a corpse channel.
    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        writer = nil
        pending.append(.closed(error))
        resumeEmptyWaiters()
        resumeFullWaiters()
        if let rc = readyContinuation {
            readyContinuation = nil
            rc.resume(throwing: error ?? CancellationError())
        }
    }

    private func fail(_ error: Error) {
        if let rc = readyContinuation {
            readyContinuation = nil
            rc.resume(throwing: error)
            finished = true
            resumeEmptyWaiters()
            resumeFullWaiters()
        } else {
            finish(error)
        }
    }

    // MARK: - Input

    /// Writes serialize on the actor — callers order bursts through their
    /// own send chain; consecutive writes keep wire order. A failed
    /// write means a dead channel: surface it as a close so the session
    /// can react instead of silently swallowing keystrokes.
    func send(_ bytes: [UInt8]) async {
        if resizeDirty {
            replayResize()
        }
        guard let writer else { return }
        do {
            try await writer.write(ByteBuffer(bytes: bytes))
        } catch {
            finish(error)
        }
    }

    func send(_ string: String) async {
        await send([UInt8](string.utf8))
    }

    // MARK: - Resize

    /// Records the newest requested size and queues a wire update. A
    /// resize only hits the wire if its sequence is still the newest
    /// when the chained task runs — bursts coalesce to the latest size.
    func setSize(cols: Int, rows: Int) {
        targetCols = max(1, cols)
        targetRows = max(1, rows)
        targetSeq += 1
        guard writer != nil else {
            resizeDirty = true
            return
        }
        enqueueResize(seq: targetSeq)
    }

    /// Re-queues the current target size (post-open, after a failed
    /// write, on the reconnect replacement channel).
    private func replayResize() {
        guard targetCols > 0, targetRows > 0 else {
            resizeDirty = false
            return
        }
        targetSeq += 1
        enqueueResize(seq: targetSeq)
    }

    private func enqueueResize(seq: Int) {
        let previous = resizeChain
        resizeChain = Task { [weak self] in
            _ = await previous?.value
            await self?.sendResize(seq)
        }
    }

    private func sendResize(_ seq: Int) async {
        // A newer request superseded this task — the latest wins.
        guard seq == targetSeq else { return }
        guard let writer, targetCols > 0 else { return }
        do {
            try await writer.changeSize(
                cols: targetCols,
                rows: targetRows,
                pixelWidth: 0,
                pixelHeight: 0
            )
            wireCols = targetCols
            wireRows = targetRows
            wireSeq = seq
            resizeDirty = false
        } catch {
            // Keep the target — the next replay (input, resize, reattach)
            // pushes it onto whatever channel is live then.
            resizeDirty = true
        }
    }

    func close() {
        task?.cancel()
        task = nil
        finish(nil)
    }
}
