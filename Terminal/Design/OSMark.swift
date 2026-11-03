import SwiftUI

/// Distro mark for a server row. A drawn glyph, never a letter.
struct OSMark: View {
    var osID: String?

    var body: some View {
        mark
            .foregroundStyle(Color.terminalAccent)
            .frame(width: 22, height: 22)
    }

    @ViewBuilder
    private var mark: some View {
        switch osID {
        case "darwin", "macos", "ios":
            Image(systemName: "applelogo")
                .font(.system(size: 16, weight: .medium))
        case "windows", "mingw64_nt", "cygwin_nt", "msys_nt":
            WindowsMark()
        case "ubuntu":
            UbuntuMark()
        case "debian":
            DebianMark()
        case "fedora", "rhel", "centos", "rocky", "almalinux":
            FedoraMark()
        case "arch", "archarm", "manjaro":
            ArchMark()
        case "alpine":
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 15, weight: .medium))
        case "freebsd", "openbsd", "netbsd":
            Image(systemName: "internaldrive")
                .font(.system(size: 15, weight: .medium))
        case "kali":
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 15, weight: .medium))
        case "openwrt", "ddwrt":
            Image(systemName: "wifi.router")
                .font(.system(size: 15, weight: .medium))
        case nil:
            Image(systemName: "server.rack")
                .font(.system(size: 15, weight: .medium))
        default:
            LinuxMark()
        }
    }
}

/// Three circles, the familiar Ubuntu arrangement.
private struct UbuntuMark: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let orbit = size.width * 0.28
            let radius = size.width * 0.16
            for index in 0..<3 {
                let angle = (CGFloat(index) * 2 * .pi / 3) - (.pi / 2)
                let point = CGPoint(
                    x: center.x + cos(angle) * orbit,
                    y: center.y + sin(angle) * orbit
                )
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .foreground)
            }
        }
    }
}

/// Open ring — Debian's swirl, reduced to a stroke that stays sharp at 22pt.
private struct DebianMark: View {
    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.92)
            .stroke(style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            .padding(2)
    }
}

/// Two overlapping discs. Reads as Fedora / enterprise Linux without a letter.
private struct FedoraMark: View {
    var body: some View {
        Canvas { context, size in
            let radius = size.width * 0.28
            let left = CGRect(x: size.width * 0.08, y: size.height * 0.22, width: radius * 2, height: radius * 2)
            let right = CGRect(x: size.width * 0.36, y: size.height * 0.22, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: left), with: .foreground, lineWidth: 1.8)
            context.fill(Path(ellipseIn: right), with: .foreground)
        }
    }
}

/// A single arch.
private struct ArchMark: View {
    var body: some View {
        ArchShape()
            .stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            .padding(2)
    }
}

private struct ArchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 1, y: rect.maxY - 1))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - 1, y: rect.maxY - 1),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.15)
        )
        return path
    }
}

/// Four panes. A window, not a desktop clipart.
private struct WindowsMark: View {
    var body: some View {
        let gap: CGFloat = 1.5
        Canvas { context, size in
            let w = (size.width - gap) / 2
            let h = (size.height - gap) / 2
            let rects = [
                CGRect(x: 0, y: 0, width: w, height: h),
                CGRect(x: w + gap, y: 0, width: w, height: h),
                CGRect(x: 0, y: h + gap, width: w, height: h),
                CGRect(x: w + gap, y: h + gap, width: w, height: h)
            ]
            for rect in rects {
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .foreground)
            }
        }
    }
}

/// Generic Linux: a ring and a core, not an initial.
private struct LinuxMark: View {
    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 2)
            Circle().frame(width: 6, height: 6)
        }
        .padding(2)
    }
}
