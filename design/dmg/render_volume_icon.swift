// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit

// usage: swift render_volume_icon.swift <in.svg> <out.png> <size>
//
// Renders a margined icon master with a transparent background. qlmanage
// honors the SVG's feDropShadow but composites onto opaque white — a white
// square around the squircle everywhere the volume icon shows. CoreSVG keeps
// transparency but silently drops <filter>, so this draws through CoreSVG and
// re-applies the master's shadow (feDropShadow dx=0 dy=10 stdDeviation=10
// flood-opacity=0.3, authored at 1024) in CoreGraphics, scaled to the
// requested size.
let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]) else {
    FileHandle.standardError.write("usage: render_volume_icon <in.svg> <out.png> <size>\n".data(using: .utf8)!)
    exit(1)
}
guard let img = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("failed to load \(args[1])\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let scale = CGFloat(size) / 1024
let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)  // SVG dy=10 is downward
shadow.shadowBlurRadius = 20 * scale                          // ~ feDropShadow stdDeviation 10
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.set()
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
