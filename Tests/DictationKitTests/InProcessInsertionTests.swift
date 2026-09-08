import AppKit
import XCTest
@testable import DictationKit

@MainActor
final class InProcessInsertionTests: XCTestCase {

    // MARK: - Fakes

    /// Records every clipboard operation so a test can prove what the injector left behind.
    final class SpyClipboard: Clipboard {
        private(set) var events: [String] = []
        var contents: String?
        init(contents: String? = nil) { self.contents = contents }
        func snapshot() -> ClipboardSnapshot {
            events.append("snapshot")
            guard let contents else { return ClipboardSnapshot(items: []) }
            return ClipboardSnapshot(items: [["str": Data(contents.utf8)]])
        }
        func writeString(_ text: String) { events.append("write:\(text)"); contents = text }
        func restore(_ snapshot: ClipboardSnapshot) {
            events.append("restore")
            contents = snapshot.items.first?["str"].map { String(decoding: $0, as: UTF8.self) }
        }
    }

    final class SpyKeystroke: PasteKeystroke {
        var accessibilityGranted = true
        func paste() throws {}
    }

    /// External injector that records its calls, standing in for the pasteboard route.
    final class SpyExternalInjector: TextInjector {
        private(set) var injected: [String] = []
        func inject(_ text: String, restoringPreviousClipboard: Bool) throws { injected.append(text) }
    }

    final class FakeTarget: InProcessInsertionTarget {
        var active: Bool
        private(set) var inserted: [String] = []
        init(active: Bool) { self.active = active }
        var isActiveInsertionTarget: Bool { active }
        func insert(_ text: String) { inserted.append(text) }
    }

    // MARK: - The stale-clipboard mechanism (the reported Add Feedback bug)

    func testPasteboardRouteLeavesOnlyTheOldClipboardForADeferredPaste() throws {
        // With restore on, the injector writes the transcript, posts ⌘V, then restores the
        // prior clipboard before returning. A self-directed paste is delivered by AppKit
        // *after* inject returns — by then the clipboard holds the original again, so the
        // editor pastes the old text. This reproduces the failure mechanism.
        let clipboard = SpyClipboard(contents: "old clipboard")
        let injector = PasteboardTextInjector(
            clipboard: clipboard, keystroke: SpyKeystroke(), settle: 0, sleep: { _ in }
        )
        try injector.inject("dictated words", restoringPreviousClipboard: true)
        // What a paste consumed after inject() returns would read:
        XCTAssertEqual(clipboard.contents, "old clipboard")
        XCTAssertEqual(clipboard.events, ["snapshot", "write:dictated words", "restore"])
    }

    // MARK: - Routing to the in-process target

    func testActiveTargetGetsDirectInsertionAndClipboardIsUntouchedWhenRestoring() throws {
        let clipboard = SpyClipboard(contents: "old clipboard")
        let external = SpyExternalInjector()
        let router = RoutingTextInjector(external: external, clipboard: clipboard)
        let target = FakeTarget(active: true)
        router.inProcessTarget = target

        try router.inject("dictated words", restoringPreviousClipboard: true)

        XCTAssertEqual(target.inserted, ["dictated words"], "inserted directly, not pasted")
        XCTAssertTrue(external.injected.isEmpty, "the external paste route is not used")
        XCTAssertEqual(clipboard.contents, "old clipboard", "restore-on: clipboard untouched")
        XCTAssertTrue(clipboard.events.isEmpty, "direct insertion never writes the clipboard")
    }

    func testActiveTargetLeavesTranscriptOnClipboardWhenRestoreDisabled() throws {
        let clipboard = SpyClipboard(contents: "old clipboard")
        let router = RoutingTextInjector(external: SpyExternalInjector(), clipboard: clipboard)
        let target = FakeTarget(active: true)
        router.inProcessTarget = target

        try router.inject("dictated words", restoringPreviousClipboard: false)

        XCTAssertEqual(target.inserted, ["dictated words"])
        // The setting promises the transcript is left on the clipboard when restore is off.
        XCTAssertEqual(clipboard.contents, "dictated words")
    }

    func testInactiveTargetFallsBackToExternalRoute() throws {
        let external = SpyExternalInjector()
        let router = RoutingTextInjector(external: external, clipboard: SpyClipboard())
        let target = FakeTarget(active: false)  // editor closed or unfocused
        router.inProcessTarget = target

        try router.inject("dictated words", restoringPreviousClipboard: true)

        XCTAssertTrue(target.inserted.isEmpty, "an inactive editor must not receive the transcript")
        XCTAssertEqual(external.injected, ["dictated words"], "routed to the external injector once")
    }

    func testNoTargetUsesExternalRoute() throws {
        let external = SpyExternalInjector()
        let router = RoutingTextInjector(external: external, clipboard: SpyClipboard())
        try router.inject("dictated words", restoringPreviousClipboard: true)
        XCTAssertEqual(external.injected, ["dictated words"])
    }

    func testExternalFailurePropagatesAndDoesNotInsertDirectly() {
        struct Boom: Error {}
        final class FailingExternal: TextInjector {
            func inject(_ text: String, restoringPreviousClipboard: Bool) throws { throw Boom() }
        }
        let router = RoutingTextInjector(external: FailingExternal(), clipboard: SpyClipboard())
        let target = FakeTarget(active: false)
        router.inProcessTarget = target
        XCTAssertThrowsError(try router.inject("x", restoringPreviousClipboard: true))
        XCTAssertTrue(target.inserted.isEmpty, "a failed external route must not double-insert")
    }

    func testTargetIsHeldWeaklySoAClosedEditorLeavesNoStaleDestination() throws {
        let external = SpyExternalInjector()
        let router = RoutingTextInjector(external: external, clipboard: SpyClipboard())
        do {
            let target = FakeTarget(active: true)
            router.inProcessTarget = target
            XCTAssertNotNil(router.inProcessTarget)
        }  // target deallocates here
        XCTAssertNil(router.inProcessTarget, "weak reference clears when the editor goes away")
        try router.inject("late transcript", restoringPreviousClipboard: true)
        XCTAssertEqual(external.injected, ["late transcript"], "falls back once the target is gone")
    }

    // MARK: - Real NSTextView editing through TextViewInsertionTarget

    func testInsertsAtTheCaretInARealTextView() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.string = "before after"
        textView.setSelectedRange(NSRange(location: 7, length: 0))  // caret before "after"
        try TextViewInsertionTarget(textView: textView).insert("NEW ")
        XCTAssertEqual(textView.string, "before NEW after")
    }

    func testReplacesTheSelectionInARealTextView() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.string = "keep REMOVE keep"
        textView.setSelectedRange(NSRange(location: 5, length: 6))  // "REMOVE"
        try TextViewInsertionTarget(textView: textView).insert("ADD")
        XCTAssertEqual(textView.string, "keep ADD keep")
    }

    func testInsertionIsUndoableInARealTextView() throws {
        // A text view gets its undo manager from its window, so give it one.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let textView = NSTextView(frame: window.contentLayoutRect)
        textView.allowsUndo = true
        window.contentView = textView
        textView.string = "original"
        textView.setSelectedRange(NSRange(location: 8, length: 0))

        try TextViewInsertionTarget(textView: textView).insert(" added")
        XCTAssertEqual(textView.string, "original added")
        XCTAssertEqual(textView.undoManager?.canUndo, true, "the insertion registers an undo action")
        // The typing undo group closes on the next run-loop pass; let it, then undo.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "original", "the dictated insertion is a single undoable edit")
    }

    func testIsInactiveWithoutAWindow() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertFalse(TextViewInsertionTarget(textView: textView).isActiveInsertionTarget)
    }

    func testIsInactiveWhenNotEditable() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.isEditable = false
        XCTAssertFalse(TextViewInsertionTarget(textView: textView).isActiveInsertionTarget)
    }
    /// A hidden window with controlled key status. No window is ordered on screen and
    /// no application is activated; AppKit still owns the actual responder chain.
    final class EditorWindow: NSWindow {
        var keyForTest = true
        override var isKeyWindow: Bool { keyForTest }
    }

    private func editor() -> (EditorWindow, NSTextView) {
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSTextView(frame: window.contentLayoutRect)
        view.isRichText = false
        view.allowsUndo = true
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertFalse(window.isVisible)
        return (window, view)
    }

    final class DeferredEditorPaste: PasteKeystroke {
        let pasteboard: NSPasteboard
        let view: NSTextView
        var accessibilityGranted = true
        init(_ pasteboard: NSPasteboard, _ view: NSTextView) {
            self.pasteboard = pasteboard
            self.view = view
        }
        func paste() throws {
            // Model the self-directed event's main-run-loop delivery without posting a
            // global keystroke or touching the user's clipboard.
            RunLoop.main.perform(inModes: [.default]) { [self] in
                MainActor.assumeIsolated {
                    XCTAssertTrue(view.readSelection(from: pasteboard, type: .string))
                }
            }
        }
    }

    func testDeferredAppKitPasteReproducesOldTextAndDirectRouteAvoidsIt() throws {
        for direct in [false, true] {
            for restore in [false, true] {
                let (window, view) = editor()
                let pasteboard = NSPasteboard.withUniqueName()
                defer { pasteboard.releaseGlobally() }
                let clipboard = SystemClipboard(pasteboard: pasteboard)
                clipboard.writeString("OLD CLIPBOARD")
                let external = PasteboardTextInjector(clipboard: clipboard,
                    keystroke: DeferredEditorPaste(pasteboard, view), settle: 0, sleep: { _ in })
                let router = RoutingTextInjector(external: external, clipboard: clipboard)
                let target = TextViewInsertionTarget(textView: view)
                router.inProcessTarget = direct ? target : nil
                try router.inject("NEW TRANSCRIPT", restoringPreviousClipboard: restore)
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                XCTAssertEqual(view.string, !direct && restore ? "OLD CLIPBOARD" : "NEW TRANSCRIPT")
                XCTAssertEqual(pasteboard.string(forType: .string), restore ? "OLD CLIPBOARD" : "NEW TRANSCRIPT")
                withExtendedLifetime((window, target)) {}
            }
        }
    }

    final class RejectingDelegate: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool { false }
    }

    func testRejectedEditThrowsWithoutClipboardChangeOrExternalRetry() throws {
        let (window, view) = editor()
        let delegate = RejectingDelegate()
        view.delegate = delegate
        view.string = "keep"
        let clipboard = SpyClipboard(contents: "old")
        let external = SpyExternalInjector()
        let router = RoutingTextInjector(external: external, clipboard: clipboard)
        let target = TextViewInsertionTarget(textView: view)
        router.inProcessTarget = target
        XCTAssertTrue(target.isActiveInsertionTarget)
        XCTAssertThrowsError(try router.inject("new", restoringPreviousClipboard: false))
        XCTAssertEqual(view.string, "keep")
        XCTAssertTrue(external.injected.isEmpty)
        XCTAssertTrue(clipboard.events.isEmpty)
        withExtendedLifetime((window, target, delegate)) {}
    }

    func testRealTargetFollowsKeyWindowAndFirstResponderAtInsertionTime() throws {
        let (window, view) = editor()
        let external = SpyExternalInjector()
        let router = RoutingTextInjector(external: external, clipboard: SpyClipboard())
        let target = TextViewInsertionTarget(textView: view)
        router.inProcessTarget = target
        XCTAssertTrue(target.isActiveInsertionTarget)
        try router.inject("here", restoringPreviousClipboard: true)
        window.keyForTest = false
        try router.inject("elsewhere", restoringPreviousClipboard: true)
        window.keyForTest = true
        window.makeFirstResponder(nil)
        try router.inject("other responder", restoringPreviousClipboard: false)
        XCTAssertEqual(view.string, "here")
        XCTAssertEqual(external.injected, ["elsewhere", "other responder"])
        window.contentView = nil
        XCTAssertFalse(target.isActiveInsertionTarget)
        withExtendedLifetime((window, target)) {}
    }

    func testFeedbackEditorUsesReadableDarkModeColors() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let dark = NSAppearance(named: .darkAqua)!
        textView.appearance = dark
        FeedbackEditorPresentation.apply(to: textView)

        var textBrightness: CGFloat = 0
        var backgroundBrightness: CGFloat = 1
        dark.performAsCurrentDrawingAppearance {
            let text = textView.textColor!.usingColorSpace(.sRGB)!
            let background = textView.backgroundColor.usingColorSpace(.sRGB)!
            textBrightness = (text.redComponent + text.greenComponent + text.blueComponent) / 3
            backgroundBrightness = (background.redComponent + background.greenComponent + background.blueComponent) / 3
        }
        XCTAssertGreaterThan(textBrightness, backgroundBrightness + 0.5)
        XCTAssertTrue(textView.drawsBackground)
    }

}
