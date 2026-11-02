#!/usr/bin/env swift
// Generates Terminal.app icon set: black squircle + ">_" glyph.
// Usage: swift scripts/make_icons.swift <output_dir>
import AppKit
import CoreGraphics

let size: CGFloat = 1024

func drawIcon(bg: NSColor, fg: NSColor, tintedOnly: Bool, outPath: String) {
    let scale: CGFloat = 1
    let pixelSize = Int(size * scale)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: pixelSize, height: pixelSize,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("ctx")
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    if !tintedOnly {
        // Background: near-black with a very subtle top light — Apple icon depth.
        ctx.setFillColor(bg.cgColor)
        ctx.fill(rect)

        let highlight = CAGradientLayer()
        highlight.frame = rect
        highlight.colors = [
            NSColor.white.withAlphaComponent(0.06).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor
        ]
        highlight.startPoint = CGPoint(x: 0.5, y: 1.0)
        highlight.endPoint = CGPoint(x: 0.5, y: 0.0)
        highlight.render(in: ctx)
    }

    // Glyph metrics — chevron ">" plus "_" cursor bar, SF Mono proportions.
    let strokeW: CGFloat = 88
    let glyphColor = fg.cgColor
    ctx.setStrokeColor(glyphColor)
    ctx.setLineWidth(strokeW)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Chevron ">": centered slightly left, optically balanced with the bar.
    let cx = size * 0.40
    let top = size * 0.635
    let bottom = size * 0.365
    let mid = size * 0.5
    let leg = size * 0.20

    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: cx - leg, y: top))
    chevron.addLine(to: CGPoint(x: cx + leg * 0.55, y: mid))
    chevron.addLine(to: CGPoint(x: cx - leg, y: bottom))
    ctx.addPath(chevron)
    ctx.strokePath()

    // Cursor bar "_" to the right of the chevron.
    let barY = bottom - strokeW * 0.12
    let barX0 = size * 0.585
    let barX1 = size * 0.825
    ctx.move(to: CGPoint(x: barX0, y: barY))
    ctx.addLine(to: CGPoint(x: barX1, y: barY))
    ctx.strokePath()

    guard let image = ctx.makeImage() else { fatalError("img") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try! png.write(to: URL(fileURLWithPath: outPath))
}

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/Terminal/Assets.xcassets/AppIcon.appiconset"

try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Light appearance: black icon, white glyph (Terminal.app language).
drawIcon(bg: NSColor(red: 0.03, green: 0.03, blue: 0.035, alpha: 1),
         fg: .white, tintedOnly: false,
         outPath: outDir + "/icon-1024.png")

// Dark appearance: inverted — off-white icon, near-black glyph.
drawIcon(bg: NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1),
         fg: NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1), tintedOnly: false,
         outPath: outDir + "/icon-1024-dark.png")

// Tinted appearance: transparent bg, dark glyph — system applies the tint.
drawIcon(bg: .clear,
         fg: NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1), tintedOnly: true,
         outPath: outDir + "/icon-1024-tinted.png")

let contents = """
{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "icon-1024-dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "tinted"
        }
      ],
      "filename" : "icon-1024-tinted.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try! contents.write(toFile: outDir + "/Contents.json", atomically: true, encoding: .utf8)
print("icons → \(outDir)")
