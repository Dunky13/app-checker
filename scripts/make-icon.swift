// Regenerates Resources/AppIcon.icns: swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let out = URL(fileURLWithPath: "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for (points, scale) in [16, 32, 128, 256, 512].flatMap({ [($0, 1), ($0, 2)] }) {
    let size = CGFloat(points * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: rounded square inset by about 10 percent.
    let tile = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.1, dy: size * 0.1)
    let path = NSBezierPath(roundedRect: tile, xRadius: size * 0.18, yRadius: size * 0.18)
    NSGradient(starting: NSColor(red: 0.16, green: 0.62, blue: 0.56, alpha: 1), ending: NSColor(red: 0.09, green: 0.32, blue: 0.47, alpha: 1))!.draw(in: path, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold).applying(.init(paletteColors: [NSColor(red: 0.09, green: 0.36, blue: 0.47, alpha: 1), .white]))
    let symbol = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    symbol.draw(in: NSRect(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
    NSGraphicsContext.current = nil
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
}
