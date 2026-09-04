import AppKit
import XCTest
@testable import DictationKit

@MainActor
final class IconRendererTests: XCTestCase {

    private func makeBase() -> NSImage {
        // A tiny opaque square stands in for the waveform mask.
        let image = NSImage(size: NSSize(width: 24, height: 18))
        image.lockFocus()
        NSColor.white.set()
        NSRect(x: 0, y: 0, width: 24, height: 18).fill()
        image.unlockFocus()
        return image
    }

    func testNormalSpecRendersAsTemplate() {
        let renderer = IconRenderer(base: makeBase())
        let image = renderer.image(for: .normal, appearance: nil)
        XCTAssertTrue(image.isTemplate, "idle uses the system-tinted template so it adapts to the menu bar")
        XCTAssertEqual(image.size, NSSize(width: 24, height: 18))
    }

    func testColoredSpecRendersAsNonTemplateDot() {
        let renderer = IconRenderer(base: makeBase())
        let image = renderer.image(
            for: IconRenderSpec(color: .recordingRed, normalWeight: 0), appearance: nil
        )
        XCTAssertFalse(image.isTemplate, "a colored state draws a non-template dot composite, not a system-tinted template")
        XCTAssertEqual(image.size, NSSize(width: 24, height: 18))
    }

    func testFullNormalWeightFallsBackToTemplateEvenWithAColor() {
        let renderer = IconRenderer(base: makeBase())
        let image = renderer.image(
            for: IconRenderSpec(color: .successBlue, normalWeight: 1), appearance: nil
        )
        XCTAssertTrue(image.isTemplate)
    }
}
