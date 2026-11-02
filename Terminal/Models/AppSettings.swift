import Foundation

struct AppSettings: Codable, Hashable, Sendable {
    /// Silent-audio background keepalive — off until the user opts in.
    var keepAlive = false
    var requireBiometry = false
    var autoTmux = true
    var fontSize: Double = 13
    /// "auto" follows the system light/dark appearance.
    var themeID = "auto"
    var appearance = Appearance.system
    var haptics = true
    /// Esc/Ctrl/arrows bar above the keyboard.
    var showKeyboardBar = true
    /// Reconnect sessions automatically when the network returns.
    var autoReconnect = true
    /// Optional absolute path replacing the login shell on connect.
    var shellOverride = ""
    /// Allow the remote host to write to the clipboard via OSC 52.
    /// Off by default — a hostile server must not touch the pasteboard.
    var remoteClipboard = false

    enum Appearance: String, Codable, Hashable, Sendable {
        case dark, light, system
    }
}
