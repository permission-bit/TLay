import AppKit

// Render our vector geometry at each required macOS icon size.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var chunks = Data()
func encodedSize(_ value: Int) -> Data {
    var size = UInt32(value).bigEndian
    return withUnsafeBytes(of: &size) { Data($0) }
}
let iconTypes = [16: ["icp4", "ic11"], 32: ["icp5", "ic12"], 128: ["ic07", "ic13"],
                 256: ["ic08", "ic14"], 512: ["ic09", "ic10"]]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: factor, y: factor)
        let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880),
                                      xRadius: 200, yRadius: 200)
        let gradient = NSGradient(starting: NSColor(red: 0.29, green: 0.25, blue: 0.89, alpha: 1),
                                  ending: NSColor(red: 0.08, green: 0.49, blue: 0.95, alpha: 1))!
        gradient.draw(in: background, angle: -60)
        for row in 0..<2 {
            for column in 0..<2 {
                NSColor.white.withAlphaComponent(row == 1 && column == 0 ? 0.98 : 0.38).setFill()
                NSBezierPath(roundedRect: NSRect(x: 236 + column * 292, y: 236 + row * 292, width: 260, height: 260),
                             xRadius: 44, yRadius: 44).fill()
            }
        }
        NSColor(red: 0.20, green: 0.32, blue: 0.85, alpha: 1).setStroke()
        let prompt = NSBezierPath()
        prompt.lineWidth = 19
        prompt.lineCapStyle = .round
        prompt.lineJoinStyle = .round
        prompt.move(to: NSPoint(x: 304, y: 699))
        prompt.line(to: NSPoint(x: 342, y: 662))
        prompt.line(to: NSPoint(x: 304, y: 625))
        prompt.move(to: NSPoint(x: 373, y: 625))
        prompt.line(to: NSPoint(x: 421, y: 625))
        prompt.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: directory.appendingPathComponent(filename))
        chunks.append(Data(iconTypes[size]![scale - 1].utf8))
        chunks.append(encodedSize(png.count + 8))
        chunks.append(png)
    }
}
var icon = Data("icns".utf8)
icon.append(encodedSize(chunks.count + 8))
icon.append(chunks)
try icon.write(to: directory.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))
