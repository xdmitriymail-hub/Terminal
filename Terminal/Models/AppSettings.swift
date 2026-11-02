import Foundation

struct AppSettings: Codable, Hashable, Sendable {
    var keepAlive = true
    var requireBiometry = false
    var autoTmux = true
    var fontSize: Double = 13
    var themeID = "pro"
    var appearance = Appearance.dark
    var haptics = true
    /// Esc/Ctrl/arrows bar above the keyboard.
    var showKeyboardBar = true
    /// Reconnect sessions automatically when the network returns.
    var autoReconnect = true
    /// Optional absolute path replacing the login shell on connect.
    var shellOverride = ""

    enum Appearance: String, Codable, Hashable, Sendable {
        case dark, light, system
    }
}
