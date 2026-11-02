import AppKit

// Renders a static mock of the new onboarding + terminal screen
// (same shapes/colors as the SwiftUI layout) to PNG files.

let W: CGFloat = 393, H: CGFloat = 852
let accent = NSColor(calibratedRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
let surface = NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)

func roundRect(_ r: CGRect, _ rad: CGFloat, _ color: NSColor, in ctx: CGContext) {
    ctx.saveGState()
    ctx.setFillColor(color.cgColor)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
}

func text(_ s: String, at p: CGPoint, size: CGFloat, _ color: NSColor, weight: NSFont.Weight = .regular, mono: Bool = false, centered width: CGFloat? = nil) {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                    : NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if let width {
        let str = NSString(string: s)
        let sz = str.size(withAttributes: attrs)
        str.draw(at: CGPoint(x: p.x + (width - sz.width) / 2, y: p.y), withAttributes: attrs)
    } else {
        NSString(string: s).draw(at: p, withAttributes: attrs)
    }
}

func makeContext() -> (CGContext, NSBitmapImageRep) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    return (gc.cgContext, rep)
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: name))
}

// MARK: - Onboarding mock

do {
    let (ctx, rep) = makeContext()
    ctx.setFillColor(NSColor.white.cgColor)   // light mode system bg
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    // hero squircle
    roundRect(CGRect(x: W/2 - 48, y: H - 48 - 96 - 40, width: 96, height: 96), 26, NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 1), in: ctx)
    text(">", at: CGPoint(x: W/2 - 18, y: H - 48 - 96 - 40 + 32), size: 30, .white, weight: .bold, mono: true)
    roundRect(CGRect(x: W/2 + 2, y: H - 48 - 96 - 40 + 34, width: 17, height: 30), 2, .white, in: ctx)

    text("Terminal", at: CGPoint(x: 0, y: H - 48 - 96 - 40 - 44), size: 28, .black, weight: .bold, centered: W)

    // feature glyphs row (simplified as chips)
    for (i, g) in ["term", "folder", "arrows"].enumerated() {
        let x = W/2 - 66 + CGFloat(i) * 44 - 4
        roundRect(CGRect(x: x, y: H - 48 - 96 - 40 - 44 - 24 - 44, width: 44, height: 44), 13,
                  NSColor.black.withAlphaComponent(0.05), in: ctx)
        text(g == "term" ? ">" : (g == "folder" ? "▱" : "⇄"), at: CGPoint(x: x + 12, y: H - 48 - 96 - 40 - 44 - 24 - 30), size: 16, accent)
    }

    // form card
    let cardY: CGFloat = 330, cardH: CGFloat = 156
    roundRect(CGRect(x: 24, y: cardY, width: W - 48, height: cardH), 16,
              NSColor.black.withAlphaComponent(0.04), in: ctx)
    let rows: [(String, String)] = [("Host", "server.example.com"), ("Username        Port", "root            22"), ("Password", "Optional")]
    for (i, r) in rows.enumerated() {
        let y = cardY + cardH - 52 * CGFloat(i + 1) + 16
        text(r.0, at: CGPoint(x: 40, y: y), size: 15, .gray)
        text(r.1, at: CGPoint(x: W - 40 - NSString(string: r.1).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)]).width, y: y), size: 15, .black, mono: true)
        if i < 2 {
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.08).cgColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: 40, y: cardY + cardH - 52 * CGFloat(i + 1)))
            ctx.addLine(to: CGPoint(x: W - 24, y: cardY + cardH - 52 * CGFloat(i + 1)))
            ctx.strokePath()
        }
    }

    // connect button
    roundRect(CGRect(x: 24, y: 250, width: W - 48, height: 50), 25, accent, in: ctx)
    text("Connect", at: CGPoint(x: 0, y: 265), size: 17, .black, weight: .semibold, centered: W)

    text("Set up later", at: CGPoint(x: 0, y: 200), size: 14, .gray, centered: W)

    save(rep, "/tmp/onboarding-mock.png")
}

// MARK: - Terminal + keyboard bar mock

do {
    let (ctx, rep) = makeContext()
    ctx.setFillColor(surface.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    // nav bar title
    ctx.setFillColor(accent.cgColor)
    ctx.fillEllipse(in: CGRect(x: W/2 - 32, y: H - 62, width: 8, height: 8))
    text("user@server", at: CGPoint(x: W/2 - 18, y: H - 66), size: 15, .white, weight: .medium)

    // terminal text lines
    let lines: [(String, NSColor)] = [
        ("$ uname -a", NSColor(white: 0.93, alpha: 1)),
        ("Linux server 6.8.0 x86_64 GNU/Linux", NSColor(white: 0.6, alpha: 1)),
        ("$ ", NSColor(white: 0.93, alpha: 1)),
    ]
    var y = H - 110
    for (l, c) in lines { text(l, at: CGPoint(x: 16, y: y), size: 13, c, mono: true); y -= 22 }
    roundRect(CGRect(x: 32, y: y + 4, width: 9, height: 16), 2, accent, in: ctx)

    // snippet bar
    for (i, s) in ["htop", "git status", "tail -f"].enumerated() {
        let x = 12 + CGFloat(i) * 88
        roundRect(CGRect(x: x, y: 420, width: 80, height: 30), 15, NSColor.white.withAlphaComponent(0.1), in: ctx)
        text(s, at: CGPoint(x: x + 10, y: 428), size: 12, .white, mono: true)
    }

    // keyboard
    ctx.setFillColor(NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: 291))
    for r in 0..<4 {
        for c in 0..<10 {
            roundRect(CGRect(x: 4 + CGFloat(c) * 39, y: 250 - CGFloat(r) * 52, width: 35, height: 46), 6,
                      NSColor.white.withAlphaComponent(0.22), in: ctx)
        }
    }

    // accessory bar (flush on top of keyboard)
    ctx.setFillColor(NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.17, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 291, width: W, height: 46))
    let keys = ["esc", "ctrl", "alt", "tab", "←", "↓", "↑", "→", "`", "|", "/", "-", "~", "⌘"]
    var kx: CGFloat = 10
    for k in keys {
        let w: CGFloat = k.count > 2 ? 42 : 34
        roundRect(CGRect(x: kx, y: 297, width: w, height: 34), 8,
                  NSColor.white.withAlphaComponent(0.12), in: ctx)
        text(k, at: CGPoint(x: kx + (w - NSString(string: k).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)]).width) / 2, y: 306), size: 13, .white, mono: true)
        kx += w + 6
    }

    save(rep, "/tmp/terminal-mock.png")
}

print("rendered")
