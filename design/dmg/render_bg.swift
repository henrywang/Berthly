// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit

// usage: swift render_bg.swift <in.svg> <out.png> <width> <height>
// Non-square variant of ../icon/render_svg.swift for the DMG background.
let args = CommandLine.arguments
guard args.count == 5, let width = Int(args[3]), let height = Int(args[4]) else {
    FileHandle.standardError.write("usage: render_bg <in.svg> <out.png> <width> <height>\n".data(using: .utf8)!)
    exit(1)
}
guard let img = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("failed to load \(args[1])\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
