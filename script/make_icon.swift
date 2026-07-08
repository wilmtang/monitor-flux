#!/usr/bin/env swift
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

// Generates Assets/AppIcon.icns (and a preview PNG) from code so the icon is
// reproducible and has no binary asset to hand-edit. Run: `swift script/make_icon.swift`.

import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func draw(size s: CGFloat) -> CGImage {
    let ctx = CGContext(
        data: nil,
        width: Int(s),
        height: Int(s),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high

    // Rounded-square panel with a transparent margin (macOS icon grid).
    let margin = s * 0.085
    let rect = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let panel = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.addPath(panel)
    ctx.clip()

    // Day -> night gradient (top warm, bottom deep blue) — the f.lux feel.
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            srgb(1.00, 0.74, 0.28),
            srgb(0.98, 0.47, 0.30),
            srgb(0.18, 0.21, 0.53),
            srgb(0.06, 0.09, 0.26),
        ] as CFArray,
        locations: [0.0, 0.42, 0.78, 1.0]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    let sunCenter = CGPoint(x: s * 0.5, y: s * 0.62)
    let sunRadius = s * 0.135

    // Soft glow behind the sun.
    let glow = CGGradient(
        colorsSpace: colorSpace,
        colors: [srgb(1, 0.95, 0.76, 0.6), srgb(1, 0.95, 0.76, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: sunCenter, startRadius: sunRadius * 0.7,
        endCenter: sunCenter, endRadius: sunRadius * 2.7,
        options: []
    )

    // Monitor silhouette (lower third) — the MonitorControl half of the app.
    let screen = CGRect(x: s * 0.5 - s * 0.23, y: s * 0.155, width: s * 0.46, height: s * 0.23)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: s * 0.028, cornerHeight: s * 0.028, transform: nil)
    ctx.setFillColor(srgb(0.04, 0.06, 0.16, 0.55))
    ctx.addPath(screenPath)
    ctx.fillPath()
    ctx.setStrokeColor(srgb(1, 1, 1, 0.9))
    ctx.setLineWidth(s * 0.015)
    ctx.addPath(screenPath)
    ctx.strokePath()
    ctx.setFillColor(srgb(1, 1, 1, 0.9))
    ctx.fill(CGRect(x: s * 0.5 - s * 0.05, y: s * 0.115, width: s * 0.10, height: s * 0.035))

    // Sun rays.
    ctx.setFillColor(srgb(1, 0.93, 0.66, 0.95))
    let rays = 8
    for index in 0 ..< rays {
        ctx.saveGState()
        ctx.translateBy(x: sunCenter.x, y: sunCenter.y)
        ctx.rotate(by: (CGFloat(index) / CGFloat(rays)) * 2 * .pi)
        let ray = CGMutablePath()
        ray.move(to: CGPoint(x: -s * 0.017, y: sunRadius * 1.32))
        ray.addLine(to: CGPoint(x: s * 0.017, y: sunRadius * 1.32))
        ray.addLine(to: CGPoint(x: 0, y: sunRadius * 1.74))
        ray.closeSubpath()
        ctx.addPath(ray)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Sun disc on top.
    ctx.setFillColor(srgb(1.0, 0.97, 0.86, 1))
    ctx.fillEllipse(in: CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius, width: 2 * sunRadius, height: 2 * sunRadius))

    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
    }
}

let specs: [(name: String, px: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for spec in specs {
    writePNG(draw(size: spec.px), to: iconset.appendingPathComponent(spec.name))
}
writePNG(draw(size: 1024), to: assets.appendingPathComponent("AppIcon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Assets/AppIcon.icns" : "iconutil failed (\(iconutil.terminationStatus))")
