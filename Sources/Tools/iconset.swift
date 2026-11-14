// Build-time helper: renders an SVG into an .iconset folder for iconutil.
//
//   iconset <icon.svg> <out.iconset>

import AppKit

let args = CommandLine.arguments
guard args.count == 3, let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write(Data("usage: iconset <icon.svg> <out.iconset>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for pt in [16, 32, 128, 256, 512] {
    try png(pt).write(to: out.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try png(pt * 2).write(to: out.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
