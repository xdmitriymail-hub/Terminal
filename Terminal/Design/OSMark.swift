import SwiftUI

/// The platform's own mark, full-bleed, with no extra tile around it.
struct OSMark: View {
    var osID: String?

    var body: some View {
        if let asset = Self.asset(for: osID) {
            Image(asset)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else if osID == "darwin" || osID == "macos" || osID == "ios" {
            Image(systemName: "applelogo")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.terminalAccent)
        } else {
            Image(systemName: "server.rack")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    static func asset(for id: String?) -> String? {
        switch id {
        case "ubuntu": return "os-ubuntu"
        case "debian": return "os-debian"
        case "fedora", "rhel", "centos", "rocky", "almalinux": return "os-fedora"
        case "arch", "archarm", "manjaro": return "os-arch"
        case "alpine": return "os-alpine"
        case "linux", "kali": return "os-linux"
        case "windows", "mingw64_nt", "cygwin_nt", "msys_nt": return "os-windows"
        case "freebsd", "openbsd", "netbsd": return "os-freebsd"
        case nil, "darwin", "macos", "ios": return nil
        default: return "os-linux"
        }
    }
}
