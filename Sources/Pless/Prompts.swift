import AppKit

/// Kleine AppKit-Dialoge (NSAlert), die sich aus SwiftUI heraus sauber aufrufen lassen.
enum Prompts {
    /// Text-Eingabe-Dialog. Liefert nil bei „Abbrechen“ oder leerer Eingabe.
    static func askText(title: String, message: String, defaultValue: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.addButton(withTitle: T("OK"))
        alert.addButton(withTitle: T("Abbrechen"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// Bestätigungs-Dialog (löschen). true = erste (gefährliche) Aktion.
    static func confirm(title: String, message: String, okTitle: String = T("Löschen")) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: okTitle)
        alert.addButton(withTitle: T("Abbrechen"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
