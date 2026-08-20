#!/usr/bin/env swift
import AppKit

// Builds an .icns from one PNG of artwork.
//
// `sips -z` would do it in a line if the artwork were always a square with the
// margin already in it, and it never is: exports come out landscape, or with the
// icon floating in a sea of transparency, or filling the canvas edge to edge.
// Fed those, `sips -z` squashes the first and leaves the other two sitting at
// different sizes in the Dock, which is exactly what "one of these is bigger
// than the other" looks like.
//
// So: find what is actually visible, drop the empty margin around it, and put it
// back centred in a square at a fixed fraction of the width. Whatever the source
// looks like, every icon built this way sits the same way in the Dock.

/// How much of the square the artwork fills.
///
/// All of it, deliberately. macOS 26 draws its own light rounded plate behind
/// every icon that is still a plain .icns, so any margin left here is not a
/// margin — it is a window onto that plate, and the icon ends up as a small
/// picture sitting inside a white box. Filling the square covers the plate.
///
/// This is what a legacy icon can do. The proper fix on 26 is to ship the new
/// format, where the artwork *is* the plate, and that needs Icon Composer.
let fill = 1.0

/// What counts as artwork to crop to.
///
/// Half-opaque rather than barely-there: these icons carry a soft glow around
/// the tile, and cropping to the last visible wisp of it would leave the tile
/// itself short of the edges, which is the whole problem again.
let visible = 0.5

// --icns writes the icon macOS has always taken. --square writes one full-bleed
// PNG, which is what the icon format on macOS 26 wants: there the artwork *is*
// the icon, and the system rounds and shades it.
guard CommandLine.arguments.count == 4,
      ["--icns", "--square"].contains(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift --icns|--square <source.png> <output>\n".utf8))
    exit(2)
}
let mode = CommandLine.arguments[1]
let source = CommandLine.arguments[2]
let output = CommandLine.arguments[3]

guard let data = try? Data(contentsOf: URL(fileURLWithPath: source)),
      let bitmap = NSBitmapImageRep(data: data) else {
    FileHandle.standardError.write(Data("cannot read \(source)\n".utf8))
    exit(1)
}

// The visible bounds, in the bitmap's own top-down coordinates.
let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
var minX = width, maxX = -1, minY = height, maxY = -1
for y in 0..<height {
    for x in 0..<width {
        guard let colour = bitmap.colorAt(x: x, y: y), colour.alphaComponent > visible else { continue }
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else {
    FileHandle.standardError.write(Data("\(source) is entirely transparent\n".utf8))
    exit(1)
}

// `draw(in:from:)` works bottom-up, so the crop rectangle is flipped back.
let crop = NSRect(x: minX,
                  y: height - 1 - maxY,
                  width: maxX - minX + 1,
                  height: maxY - minY + 1)
let longest = max(crop.width, crop.height)

func render(side: Int, to url: URL) throws {
    guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: side, pixelsHigh: side,
                                        bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
    NSGraphicsContext.current?.imageInterpolation = .high

    // Aspect preserved: the longer side gets the budget, the shorter one keeps
    // its proportion and gains margin. Squashing an icon to fill a square is
    // worse than an icon that is not quite square.
    let scale = Double(side) * fill / longest
    let drawn = NSSize(width: crop.width * scale, height: crop.height * scale)
    let target = NSRect(x: (Double(side) - drawn.width) / 2,
                        y: (Double(side) - drawn.height) / 2,
                        width: drawn.width, height: drawn.height)
    bitmap.draw(in: target, from: crop, operation: .copy, fraction: 1,
                respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])

    NSGraphicsContext.restoreGraphicsState()

    guard let png = canvas.representation(using: .png, properties: [:]) else { return }
    try png.write(to: url)
}

if mode == "--square" {
    try render(side: 1024, to: URL(fileURLWithPath: output))
    exit(0)
}

let sizes = [16, 32, 128, 256, 512]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }


for size in sizes {
    try render(side: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(side: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", iconset.path, "--output", output]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
