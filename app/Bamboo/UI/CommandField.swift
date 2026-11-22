import AppKit
import SwiftUI

/// The borderless single-line field used by the command bar, the command
/// palette and the find bar. It is AppKit rather than SwiftUI because inline
/// autocomplete needs to set the selected range, and ↑/↓, Return, Tab and Esc
/// must reach us before the field editor handles them.
struct CommandField: NSViewRepresentable {
    var placeholder: String
    /// Text the field starts with, selected so typing replaces it.
    var initialText = ""
    var fontSize: CGFloat = 20
    /// Called after every edit. Return a longer string that starts with the
    /// typed text to complete it inline; the added part is selected.
    /// `allowsCompletion` is false right after a deletion.
    var onEdit: (_ text: String, _ allowsCompletion: Bool) -> String?
    var onMove: ((Int) -> Void)?
    var onSubmit: (NSEvent.ModifierFlags) -> Void
    var onCancel: () -> Void
    /// The field lost keyboard focus (the user clicked elsewhere).
    var onEndEditing: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.placeholderString = placeholder
        field.stringValue = initialText
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField
        private var lastEditWasDeletion = false

        init(parent: CommandField) {
            self.parent = parent
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onEndEditing?()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let editor = field.currentEditor() else { return }
            let typed = field.stringValue
            let allowsCompletion = !lastEditWasDeletion
            lastEditWasDeletion = false
            guard let completion = parent.onEdit(typed, allowsCompletion),
                  completion.count > typed.count,
                  completion.lowercased().hasPrefix(typed.lowercased())
            else { return }
            // Keep the user's own capitalisation for the part they typed.
            let added = String(completion.dropFirst(typed.count))
            field.stringValue = typed + added
            editor.selectedRange = NSRange(location: (typed as NSString).length, length: (added as NSString).length)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                guard let onMove = parent.onMove else { return false }
                onMove(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                guard let onMove = parent.onMove else { return false }
                onMove(1)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onSubmit(NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? [])
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)):
                // Tab accepts the inline completion by moving the caret past it.
                let length = (textView.string as NSString).length
                if textView.selectedRange.length > 0, NSMaxRange(textView.selectedRange) == length {
                    textView.selectedRange = NSRange(location: length, length: 0)
                    _ = parent.onEdit(textView.string, false)
                }
                return true
            case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
                 #selector(NSResponder.deleteWordBackward(_:)), #selector(NSResponder.deleteToBeginningOfLine(_:)):
                lastEditWasDeletion = true
                return false
            default:
                return false
            }
        }
    }
}

/// Takes keyboard focus as soon as it is on screen, with its text selected.
final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}
