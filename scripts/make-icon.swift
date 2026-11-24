// Regenerates the icon and the README logo:
// swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns && cp "build/AppIcon.iconset/icon_128x128@2x.png" Resources/logo.png
import AppKit

let out = URL(fileURLWithPath: "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func colour(_ hex: Int) -> NSColor {
    NSColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

/// An ellipse around `centre`, turned by `degrees`.
func oval(_ centre: NSPoint, _ width: CGFloat, _ height: CGFloat, turned degrees: CGFloat = 0) -> NSBezierPath {
    let path = NSBezierPath(ovalIn: NSRect(x: -width / 2, y: -height / 2, width: width, height: height))
    var transform = AffineTransform(translationByX: centre.x, byY: centre.y)
    transform.rotate(byDegrees: degrees)
    path.transform(using: transform)
    return path
}

func shape(_ points: [NSPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: points[0])
    points.dropFirst().forEach(path.line)
    path.close()
    return path
}

for (points, scale) in [16, 32, 128, 256, 512].flatMap({ [($0, 1), ($0, 2)] }) {
    let size = CGFloat(points * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Everything below is drawn on a square of 1 by 1.
    (AffineTransform(scaleByX: size, byY: size) as NSAffineTransform).concat()

    // macOS icon grid: rounded square inset by about 10 percent. Dark as a coal mine, so the canary is what you see.
    let tile = NSBezierPath(roundedRect: NSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), xRadius: 0.18, yRadius: 0.18)
    NSGradient(starting: colour(0x3a3d46), ending: colour(0x17181c))!.draw(in: tile, angle: -90)

    let yellow = colour(0xffd21f), shade = colour(0xf0ad00), orange = colour(0xf28c1e), dark = colour(0x17181c)

    // The perch, behind the bird.
    colour(0x8a8f9c).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0.2, y: 0.28, width: 0.6, height: 0.035), xRadius: 0.0175, yRadius: 0.0175).fill()

    shade.setFill()
    shape([NSPoint(x: 0.40, y: 0.5), NSPoint(x: 0.17, y: 0.36), NSPoint(x: 0.21, y: 0.3), NSPoint(x: 0.42, y: 0.39)]).fill()   // tail

    orange.setFill()
    shape([NSPoint(x: 0.72, y: 0.72), NSPoint(x: 0.84, y: 0.665), NSPoint(x: 0.72, y: 0.63)]).fill()   // beak
    for x in [0.50, 0.57] { NSBezierPath(rect: NSRect(x: x, y: 0.3, width: 0.018, height: 0.09)).fill() }   // legs

    yellow.setFill()
    oval(NSPoint(x: 0.49, y: 0.49), 0.40, 0.29, turned: 25).fill()   // body
    oval(NSPoint(x: 0.63, y: 0.67), 0.23, 0.23).fill()   // head

    shade.setFill()
    oval(NSPoint(x: 0.44, y: 0.49), 0.25, 0.14, turned: 20).fill()   // wing

    dark.setFill()
    oval(NSPoint(x: 0.665, y: 0.695), 0.04, 0.04).fill()   // eye

    NSGraphicsContext.current = nil
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
}
