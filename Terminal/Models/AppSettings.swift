import Foundation

struct AppSettings: Codable, Hashable, Sendable {
    var keepAlive = true
    var requireBiometry = false
    var autoTmux = true
    var fontSize: Double = 13
    var themeID = "pro"
    var appearance = Appearance.dark
    var haptics = true
    /// Optional absolute path replacing the login shell on connect.
    var shellOverride = ""

    enum Appearance: String, Codable, Hashable, Sendable {
        case dark, light, system
    }
}
