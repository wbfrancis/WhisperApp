import AppKit

/// Turns an `IconRenderSpec` into a menu-bar `NSImage`: the waveform plus a status dot.
///
/// A normal spec is drawn as a template image so the system tints the waveform for the
/// light or dark menu bar (idle never fades to invisible). A colored spec draws the same
/// waveform in the resolved menu-bar color and overlays a status dot in the bottom-right,
/// at a prominence of `1 - normalWeight` — so recording is a solid dot, a pulse dims it,
/// and the success fade eases it out. The normal template is built once and reused; dot
/// frames are the only per-frame allocation, and a held solid dot is cached.
@MainActor
public final class IconRenderer {
    private let base: NSImage
    private let size: NSSize
    private lazy var templateImage: NSImage = makeTemplate()
    private var cachedDotKey: String?
    private var cachedDotImage: NSImage?

    /// - Parameter base: the waveform mask (the bundled template PNG, or a fallback symbol).
    public init(base: NSImage, size: NSSize = NSSize(width: 24, height: 18)) {
        self.base = base
        self.size = size
    }

    public func image(for spec: IconRenderSpec, appearance: NSAppearance?) -> NSImage {
        guard let color = spec.color, spec.normalWeight < 1 else {
            return templateImage
        }
        let opacity = 1 - spec.normalWeight  // dot prominence
        let normal = resolvedNormalColor(appearance)
        let key = dotKey(color: color, opacity: opacity, waveform: normal)
        if key == cachedDotKey, let cached = cachedDotImage { return cached }
        let image = withDot(color: color, opacity: opacity, waveform: normal)
        cachedDotKey = key
        cachedDotImage = image
        return image
    }

    private func makeTemplate() -> NSImage {
        let image = base.copy() as? NSImage ?? base
        image.size = size
        image.isTemplate = true
        image.accessibilityDescription = "Dictation"
        return image
    }

    /// The waveform in the normal menu-bar color with a status dot in the bottom-right. It
    /// can't be a template (a template is one flat color), so the waveform is painted in the
    /// resolved normal color to match the idle look at this instant.
    private func withDot(color: IconColor, opacity: Double, waveform: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        let context = NSGraphicsContext.current
        let rect = NSRect(origin: .zero, size: size)

        // Waveform, tinted to the normal appearance.
        base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        waveform.set()
        rect.fill(using: .sourceAtop)

        // Punch a clean disc out from under the dot so it reads over the waveform, then
        // fill the dot in the foreground.
        let dot = dotRect()
        context?.compositingOperation = .clear
        NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
        context?.compositingOperation = .sourceOver
        NSColor(srgbRed: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue),
                alpha: CGFloat(min(1, max(0, opacity)))).set()
        NSBezierPath(ovalIn: dot).fill()

        image.isTemplate = false
        image.accessibilityDescription = "Dictation"
        return image
    }

    /// The status dot: a small disc tucked into the bottom-right corner.
    private func dotRect() -> NSRect {
        let diameter: CGFloat = 8
        let inset: CGFloat = 0.5
        return NSRect(
            x: size.width - diameter - inset,
            y: inset,
            width: diameter,
            height: diameter
        )
    }

    /// The normal menu-bar foreground, always returned in sRGB so its components are safe
    /// to read. `labelColor` is a dynamic catalog color and can't be sampled directly, so
    /// it's resolved within the target appearance and falls back to black if it won't
    /// convert (e.g. in a headless test with no drawing context).
    private func resolvedNormalColor(_ appearance: NSAppearance?) -> NSColor {
        var resolved: NSColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        // NSApp can be nil off the app (e.g. in a headless test), so fall back to a
        // concrete appearance rather than force-unwrapping it.
        let target = appearance ?? NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)
        target?.performAsCurrentDrawingAppearance {
            if let rgb = NSColor.labelColor.usingColorSpace(.sRGB) { resolved = rgb }
        }
        return resolved
    }

    private func dotKey(color: IconColor, opacity: Double, waveform: NSColor) -> String {
        // Quantize so near-identical frames share a cache slot without visible banding.
        func q(_ v: Double) -> Int { Int((v * 255).rounded()) }
        let rgb = waveform.usingColorSpace(.sRGB) ?? waveform
        return "\(q(color.red))-\(q(color.green))-\(q(color.blue))-\(q(opacity))"
            + "-\(q(Double(rgb.redComponent)))-\(q(Double(rgb.greenComponent)))-\(q(Double(rgb.blueComponent)))"
    }
}
