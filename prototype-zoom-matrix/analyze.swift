#!/usr/bin/env swift
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

// Blob finder: locates the uniquely colored probe markers in a window screenshot.
// Usage: analyze.swift <in.png> <out.json>
// Output: {"probe-name": {"count": n, "cx": px, "cy": px, "minX":..,"minY":..,"maxX":..,"maxY":..}, ...}
// Coordinates are image pixels, origin top-left.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write(Data("usage: analyze.swift <png> <json>\n".utf8)); exit(2) }

guard let img = NSImage(contentsOfFile: args[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8)); exit(1)
}

let w = cg.width, h = cg.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)

// Empirical values as captured from the P3 built-in display (sRGB-converted),
// measured from a real screenshot — not the nominal sRGB source colors.
let palette: [(String, Int, Int, Int)] = [
    ("calib", 236, 52, 244),
    ("nav-schedule", 116, 252, 76),
    ("nav-general", 252, 252, 84),
    ("btn-top", 236, 52, 36),
    ("toggle-a", 116, 252, 252),
    ("btn-trailing", 236, 132, 52),
    ("btn-bottom", 116, 20, 244),
]

struct Acc { var count = 0; var sx = 0.0; var sy = 0.0
             var minX = Int.max; var minY = Int.max; var maxX = 0; var maxY = 0 }
var accs = [Acc](repeating: Acc(), count: palette.count)

let capSq = 60 * 60
for y in stride(from: 0, to: h, by: 2) {
    for x in stride(from: 0, to: w, by: 2) {
        let o = (y * w + x) * 4
        let r = Int(buf[o]), g = Int(buf[o + 1]), b = Int(buf[o + 2])
        // quick reject: grays and near-black/white (most of the UI)
        let mx = max(r, g, b), mn = min(r, g, b)
        if mx - mn < 60 { continue }
        var best = -1, bestD = Int.max
        for (i, p) in palette.enumerated() {
            let d = (r - p.1) * (r - p.1) + (g - p.2) * (g - p.2) + (b - p.3) * (b - p.3)
            if d < bestD { bestD = d; best = i }
        }
        if bestD <= capSq {
            accs[best].count += 1
            accs[best].sx += Double(x); accs[best].sy += Double(y)
            accs[best].minX = min(accs[best].minX, x); accs[best].minY = min(accs[best].minY, y)
            accs[best].maxX = max(accs[best].maxX, x); accs[best].maxY = max(accs[best].maxY, y)
        }
    }
}

var out: [String: [String: Double]] = [:]
for (i, p) in palette.enumerated() {
    let a = accs[i]
    guard a.count >= 40 else { continue }
    out[p.0] = ["count": Double(a.count),
                "cx": a.sx / Double(a.count), "cy": a.sy / Double(a.count),
                "minX": Double(a.minX), "minY": Double(a.minY),
                "maxX": Double(a.maxX), "maxY": Double(a.maxY),
                "imgW": Double(w), "imgH": Double(h)]
}
let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
try data.write(to: URL(fileURLWithPath: args[2]))
print("found: \(out.keys.sorted().joined(separator: ", "))")
