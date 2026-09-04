import AppKit
import DictationKit
import UniformTypeIdentifiers

@MainActor
final class FileResultWindowController: NSWindowController, NSWindowDelegate {
    private let rawTranscript: String
    private let sourceURL: URL
    private let isPartial: Bool
    private let normalizer: any TextNormalizer
    private let textView = NSTextView()
    private let normalizeButton = NSButton(title: "Normalize Text", target: nil, action: nil)
    var onClose: (() -> Void)?

    init(result: FileTranscriptionResult, normalizer: any TextNormalizer) {
        rawTranscript = result.text
        sourceURL = result.sourceURL
        isPartial = result.isPartial
        self.normalizer = normalizer

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Audio File Transcript"
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        let state = NSTextField(labelWithString: FileResultPresentation.stateLabel(isPartial: isPartial))
        state.font = .boldSystemFont(ofSize: 13)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.string = rawTranscript
        textView.autoresizingMask = [.width]
        scroll.documentView = textView

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyText))
        let save = NSButton(title: "Save…", target: self, action: #selector(saveText))
        normalizeButton.target = self
        normalizeButton.action = #selector(normalizeText)
        let buttons = NSStackView(views: [copy, save, normalizeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [state, scroll, buttons])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        window.center()
        window.makeFirstResponder(textView)
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc private func saveText() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = FileResultPresentation.suggestedFilename(
            sourceURL: sourceURL, isPartial: isPartial
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try textView.string.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func normalizeText() {
        let normalized = normalizer.normalize(textView.string)
        guard normalized != textView.string else { normalizeButton.isEnabled = false; return }
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        if textView.shouldChangeText(in: range, replacementString: normalized) {
            textView.insertText(normalized, replacementRange: range)
        }
        normalizeButton.isEnabled = false
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
