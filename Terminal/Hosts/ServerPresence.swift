import Foundation
import Network

/// Whether a server's SSH port accepts a TCP connection.
/// This is the host, not a terminal tab: a closed shell does not make
/// the machine offline, and a tab that is still connecting does not
/// make it online.
@MainActor
final class ServerPresence: ObservableObject {
    static let shared = ServerPresence()

    @Published private(set) var online: [UUID: Bool] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func refresh(_ profiles: [ServerProfile]) {
        let live = Set(profiles.map(\.id))
        for id in tasks.keys where !live.contains(id) {
            tasks[id]?.cancel()
            tasks[id] = nil
        }
        for profile in profiles {
            let id = profile.id
            let host = profile.host
            let port = profile.port
            guard !host.isEmpty, (1...65535).contains(port) else {
                online[id] = false
                continue
            }
            tasks[id]?.cancel()
            tasks[id] = Task {
                let up = await Self.probe(host: host, port: port)
                guard !Task.isCancelled else { return }
                online[id] = up
            }
        }
    }

    /// One TCP handshake, then close. Two and a half seconds is enough
    /// to tell a dead address from a slow one without sitting on the row.
    private static func probe(host: String, port: Int) async -> Bool {
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? 22
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let box = ProbeBox(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.finish(true)
                case .failed, .cancelled:
                    box.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5) {
                box.finish(false)
            }
        }
    }
}

/// Resumes the probe exactly once and tears the socket down.
private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private let connection: NWConnection

    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.cancel()
        pending.resume(returning: value)
    }
}
