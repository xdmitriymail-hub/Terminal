import Foundation

struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var host = ""
    var port = 22
    var username = ""
    var auth = AuthMethod.password
    var jumpProfileID: UUID?
    var forwards: [PortForward] = []
    var autoTmux = true
    var lastConnected: Date?
    /// Detected server OS — filled after the first successful connect.
    /// `osID` drives the row icon ("ubuntu", "darwin", "linux"…),
    /// `osName` is the human label shown under the username.
    var osID: String?
    var osName: String?

    enum AuthMethod: Codable, Hashable, Sendable {
        case password
        case key(UUID)

        var usesKey: Bool {
            if case .key = self { return true }
            return false
        }
    }

    var displayName: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }

    var endpoint: String {
        port == 22 ? host : "\(host):\(port)"
    }
}

struct PortForward: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind = Kind.local
    var listenPort = 8080
    var targetHost = "localhost"
    var targetPort = 8080
    var enabled = false

    enum Kind: String, Codable, Hashable, Sendable {
        case local, remote, dynamic
    }
}

struct Snippet: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    var command = ""
    var autoEnter = false
}
