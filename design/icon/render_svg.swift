import AppKit

// usage: swift render_svg.swift <in.svg> <out.png> <size>
let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]) else {
    FileHandle.standardError.write("usage: render_svg <in.svg> <out.png> <size>\n".data(using: .utf8)!)
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
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
