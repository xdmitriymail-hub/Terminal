import Foundation
import Citadel
import NIO
import NIOSSH

/// One interactive PTY channel: terminal output as an async stream,
/// typed input via `send`, resize via `setSize`.
final class ShellChannel: @unchecked Sendable {

    enum Event {
        case output(Data)
        case closed(Error?)
    }

    private var writer: Citadel.TTYStdinWriter?
    private var continuation: AsyncThrowingStream<Event, Error>.Continuation
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var task: Task<Void, Never>?
    private var lastCols = 0
    private var lastRows = 0

    let output: AsyncThrowingStream<Event, Error>

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
                    self?.attach(writer: outbound)
                    for try await item in inbound {
                        guard let self else { return }
                        switch item {
                        case .stdout(let buffer), .stderr(let buffer):
                            self.continuation.yield(.output(Data(buffer.readableBytesView)))
                        }
                    }
                }
                self?.finish(nil)
            } catch {
                self?.fail(error)
            }
        }

        try await waitReady()
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

    /// Chained write queue — independent fire-and-forget Tasks can be
    /// scheduled out of order, reordering typed input on the wire.
    private var sendChain: Task<Void, Never>?

    func send(_ bytes: [UInt8]) {
        guard let writer else { return }
        let previous = sendChain
        sendChain = Task {
            _ = await previous?.value
            try? await writer.write(ByteBuffer(bytes: bytes))
        }
    }

    func send(_ string: String) {
        send([UInt8](string.utf8))
    }

    func setSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        lastCols = cols
        lastRows = rows
        guard let writer else { return }
        Task {
            try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    func close() {
        task?.cancel()
        task = nil
        finish(nil)
    }

    /// SSH-level keepalive: re-sends the current window size — a harmless
    /// no-op for the remote shell that keeps NAT state warm.
    func keepAlive() {
        guard lastCols > 0, lastRows > 0, let writer else { return }
        let (cols, rows) = (lastCols, lastRows)
        Task {
            try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
        }
    }
}
