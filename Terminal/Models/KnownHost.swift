import Foundation

struct KnownHost: Codable, Identifiable, Hashable, Sendable {
    var id: String { key }
    var key: String
    var publicKeyOpenSSH: String
    var firstSeen = Date()
    var lastSeen = Date()

    init(host: String, port: Int, publicKeyOpenSSH: String) {
        self.key = "\(host):\(port)"
        self.publicKeyOpenSSH = publicKeyOpenSSH
    }
}
