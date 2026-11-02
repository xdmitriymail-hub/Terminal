import Foundation
import Citadel
import NIO
import NIOSSH

/// One interactive PTY channel: terminal output as an async stream,
/// typed input via `send`, resize via `setSize`.
actor ShellChannel {

    enum Event: Sendable {
        case output(Data)
        case closed(Error?)
    }

    private var writer: Citadel.TTYStdinWriter?
    private var continuation: AsyncThrowingStream<Event, Error>.Continuation
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var task: Task<Void, Never>?
    private var lastCols = 0
    private var lastRows = 0

    /// Output ordering is preserved end-to-end; the stream is deliberately
    /// unbounded — dropping terminal bytes would corrupt the rendering.
    nonisolated let output: AsyncThrowingStream<Event, Error>

    init() {
        var cont: AsyncThrowingStream<Event, Error>.Continuation!
        output = AsyncThrowingStream { cont = $0 }
        continuation = cont
    }

    deinit { task?.cancel() }

    func open(on client: Citadel.SSHClient, cols: Int, rows: Int) async throws {
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
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

        try await waitReady()
    }

    private func emit(_ data: Data) {
        continuation.yield(.output(data))
    }

    private func attach(writer: Citadel.TTYStdinWriter) {
        self.writer = writer
        readyContinuation?.resume()
        readyContinuation = nil
    }

    private func finish(_ error: Error?) {
        // Notify before finishing so the consumer can mark the session
        // offline — a silent stream end would leave stale "online" state.
        continuation.yield(.closed(error))
        continuation.finish()
        if let rc = readyContinuation {
            readyContinuation = nil
            rc.resume(throwing: error ?? CancellationError())
        }
    }

    private func fail(_ error: Error) {
        if let rc = readyContinuation {
            readyContinuation = nil
            rc.resume(throwing: error)
        } else {
            continuation.yield(.closed(error))
            continuation.finish()
        }
    }

    private func waitReady() async throws {
        try await withCheckedThrowingContinuation { cont in
            readyContinuation = cont
        }
    }

    /// Writes serialize on the actor — callers order bursts through their
    /// own send chain; consecutive writes keep wire order.
    func send(_ bytes: [UInt8]) async {
        guard let writer else { return }
        try? await writer.write(ByteBuffer(bytes: bytes))
    }

    func send(_ string: String) async {
        await send([UInt8](string.utf8))
    }

    func setSize(cols: Int, rows: Int) async {
        guard cols > 0, rows > 0 else { return }
        lastCols = cols
        lastRows = rows
        guard let writer else { return }
        try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    func close() {
        task?.cancel()
        task = nil
        finish(nil)
    }
}
