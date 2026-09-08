import AppKit

@MainActor
public enum FeedbackEditorPresentation {
    public static func apply(to textView: NSTextView) {
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor
        textView.usesAdaptiveColorMappingForDarkAppearance = true
    }
}

/// A text destination the app owns and can insert into directly, without the pasteboard
/// + synthesized ⌘V round trip. The Add Feedback editor registers one of these while its
/// modal is up so a dictated transcript lands in it through the normal text-editing path.
///
/// The pasteboard route fails for a self-directed paste: the injector restores the prior
/// clipboard on the main thread before AppKit delivers the synthesized ⌘V to the editor,
/// so the editor pastes the old clipboard. Inserting directly is synchronous and never
/// touches the clipboard, so it can't lose that race.
@MainActor
public protocol InProcessInsertionTarget: AnyObject {
    /// Whether this is the live editing destination *right now* — a positive identity check
    /// (its window is key and it holds first responder), not merely "our app is frontmost".
    /// A closed or unfocused editor returns false so a late transcript can't land in it.
    var isActiveInsertionTarget: Bool { get }
    /// Insert `text` at the insertion point, replacing any selection, with Undo support.
    func insert(_ text: String) throws
}

/// A `TextInjector` that prefers an app-owned in-process target when one is the live
/// editing destination, and otherwise routes to the external pasteboard injector. Routing
/// lives here, at the app boundary, rather than in `DictationController`.
@MainActor
public final class RoutingTextInjector: TextInjector {
    private let external: TextInjector
    private let clipboard: Clipboard
    /// Weak so a closed editor can't leave a stale destination even if the app forgets to
    /// clear it; the app also clears it explicitly when the editor dismisses.
    public weak var inProcessTarget: InProcessInsertionTarget?

    public init(external: TextInjector, clipboard: Clipboard = SystemClipboard()) {
        self.external = external
        self.clipboard = clipboard
    }

    public func inject(_ text: String, restoringPreviousClipboard: Bool) throws {
        if let target = inProcessTarget, target.isActiveInsertionTarget {
            try target.insert(text)
            // Honor the clipboard promise even on the direct route: restore-off means the
            // setting leaves the transcript on the clipboard; restore-on means the
            // clipboard is left untouched (direct insertion never wrote to it).
            if !restoringPreviousClipboard {
                clipboard.writeString(text)
            }
            return
        }
        try external.inject(text, restoringPreviousClipboard: restoringPreviousClipboard)
    }
}

/// An `InProcessInsertionTarget` backed by a real `NSTextView` — the Add Feedback editor.
/// Holds the view weakly so a dismissed editor becomes an inactive, then nil, target.
@MainActor
public final class TextViewInsertionTarget: InProcessInsertionTarget {
    public enum InsertionError: Error {
        case editorUnavailable
        case editRejected
    }
    private weak var textView: NSTextView?

    public init(textView: NSTextView) {
        self.textView = textView
    }

    public var isActiveInsertionTarget: Bool {
        guard let textView, textView.isEditable,
              let window = textView.window, window.isKeyWindow
        else { return false }
        return window.firstResponder === textView
    }

    public func insert(_ text: String) throws {
        guard let textView, textView.isEditable, let storage = textView.textStorage else {
            throw InsertionError.editorUnavailable
        }
        // `selectedRange()` is the caret when empty and the selection otherwise, so this
        // both inserts at the cursor and replaces a selection. The shouldChangeText /
        // replaceCharacters / didChangeText bracket registers exactly one undoable edit
        // and posts the change notifications, matching a typed edit.
        let range = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: text) else {
            throw InsertionError.editRejected
        }
        storage.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        let caret = range.location + (text as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
    }
}
