import SwiftUI
import UIKit

/// A single-line text field that can select all its text on demand — used for
/// renaming, where a long-press should highlight the existing name so the next
/// keystroke replaces it. SwiftUI's TextField has no select-all hook, hence UIKit.
struct SelectAllTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: UIFont = .preferredFont(forTextStyle: .subheadline)
    /// Flip to true to focus the field and select all its text; it resets itself.
    @Binding var selectAllTrigger: Bool

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.delegate = context.coordinator
        tf.placeholder = placeholder
        tf.font = font
        tf.returnKeyType = .done
        tf.clearButtonMode = .whileEditing
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.addTarget(context.coordinator,
                     action: #selector(Coordinator.editingChanged(_:)),
                     for: .editingChanged)
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text { uiView.text = text }
        if selectAllTrigger {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
                uiView.selectAll(nil)
                selectAllTrigger = false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        @objc func editingChanged(_ tf: UITextField) { text.wrappedValue = tf.text ?? "" }

        func textFieldShouldReturn(_ tf: UITextField) -> Bool {
            tf.resignFirstResponder()
            return true
        }
    }
}

extension UIFont {
    /// A bold dynamic-type font for the given text style.
    static func preferredBold(_ style: UIFont.TextStyle) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: 0)
    }
}
