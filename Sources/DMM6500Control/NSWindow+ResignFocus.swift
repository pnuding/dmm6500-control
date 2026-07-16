import AppKit

extension NSWindow {
    /// AppKit auto-focuses the first text-field-like control whenever a
    /// window - or a popover, which is backed by its own transient
    /// non-activating panel - first appears. Unwanted here: it makes an
    /// untouched field look selected. Only actually resigns focus when a
    /// text field genuinely has it - AppKit's shared field editor for any
    /// focused NSTextField-backed control is always an NSTextView - rather
    /// than unconditionally on every call site.
    func resignFirstResponderIfEditingText() {
        guard firstResponder is NSTextView else { return }
        makeFirstResponder(nil)
    }
}
