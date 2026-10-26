import UIKit

/// Every typing box in a dialog opens with its text selected, so the first key typed
/// replaces it rather than adding to it: tempo, renaming a song, section, snapshot or
/// MIDI template, a new song's name, an export name, chord positions.
///
/// One rule for the whole app, rather than a change to each field: SwiftUI's TextField
/// (including those in alerts) has no select-all hook, but every one is a UITextField
/// underneath, and UIKit announces when one starts editing.
///
/// Left alone: the inline name fields on the song screen (SelectAllTextField), where a
/// tap places the cursor and a long press selects the name, and search fields.
enum SelectAllOnEdit {
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UITextField.textDidBeginEditingNotification, object: nil, queue: .main
        ) { note in
            guard let field = note.object as? UITextField,
                  !(field is UISearchTextField),
                  !(field.delegate is SelectAllTextField.Coordinator) else { return }
            // On the next turn: selecting during begin-editing is undone by the tap or
            // the alert placing the cursor at the end.
            DispatchQueue.main.async {
                guard field.isFirstResponder, !(field.text ?? "").isEmpty else { return }
                field.selectAll(nil)
            }
        }
    }
}
