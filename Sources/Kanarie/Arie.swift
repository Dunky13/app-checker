import AppKit
import SwiftUI

/// Arie as a one-colour template image, tinted by the menu bar or the view like an SF Symbol.
@MainActor
enum Arie {
    static func image(_ path: String, in box: CGRect, height: CGFloat) -> NSImage {
        let scale = height / box.height
        // AppKit may draw an image on any thread.
        let image = NSImage(size: NSSize(width: box.width * scale, height: height), flipped: true) { @Sendable _ in
            // The paths are polygons, "M x y x y … Z" per ring; even-odd cuts out the holes and the eye.
            let shape = NSBezierPath()
            shape.windingRule = .evenOdd
            for ring in path.split(separator: "M") {
                // Generated data: a token that is not a number would shift every point after it.
                let n = ring.split(whereSeparator: { $0 == " " || $0 == "Z" }).map { Double($0)! }
                for i in stride(from: 0, to: n.count - 1, by: 2) {
                    let point = NSPoint(x: (n[i] - box.minX) * scale, y: (n[i + 1] - box.minY) * scale)
                    if i == 0 { shape.move(to: point) } else { shape.line(to: point) }
                }
                if !n.isEmpty { shape.close() }
            }
            NSColor.black.setFill()
            shape.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    static let menu = image(menuPath, in: menuBox, height: 16)
    static let menuAttention = image(menuAttentionPath, in: menuBox, height: 16)
    static let empty = image(emptyPath, in: emptyBox, height: 44)

    /// For ContentUnavailableView, in the place of its symbol.
    static func emptyState(_ title: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: empty).renderingMode(.template).accessibilityHidden(true)
        }
    }
}
