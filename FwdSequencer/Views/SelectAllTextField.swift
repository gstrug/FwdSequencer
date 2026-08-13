import SwiftUI
import UIKit

/// A single-line text field that can select all its text on demand — used for
/// renaming, where a long-press should highlight the existing name so the next
/// keystroke replaces it. SwiftUI's TextField has no select-all hook, hence UIKit.
struct SelectAllTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: UIFont = .preferredFont(forTextStyle: .subheadline)
    var maximumLength: Int = SongValidator.maximumNameLength
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
        // Hold the font-derived height so SwiftUI can't stretch the field vertically to
        // fill the proposed space (which blew the settings bar up to half the screen).
        tf.setContentHuggingPriority(.required, for: .vertical)
        tf.setContentCompressionResistancePriority(.required, for: .vertical)
        tf.addTarget(context.coordinator,
                     action: #selector(Coordinator.editingChanged(_:)),
                     for: .editingChanged)
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        // Refresh the coordinator's captured binding — the view struct (and its
        // bindings) is recreated on each update, but the coordinator is not, so
        // without this a reused field writes to a stale binding (e.g. the wrong
        // section after switching selection).
        context.coordinator.parent = self
        if uiView.text != text { uiView.text = text }
        if selectAllTrigger {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
                uiView.selectAll(nil)
                selectAllTrigger = false
            }
        }
    }

    // Pin the field to its font-derived height; let width follow the proposal. Without
    // this a representable fills the proposed height and stretches the row.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        let h = uiView.intrinsicContentSize.height
        let w = proposal.width ?? uiView.intrinsicContentSize.width
        return CGSize(width: w, height: h)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SelectAllTextField
        init(_ parent: SelectAllTextField) { self.parent = parent }

        @objc func editingChanged(_ tf: UITextField) {
            let value = String((tf.text ?? "").prefix(parent.maximumLength))
            if tf.text != value { tf.text = value }
            parent.text = value
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            guard let current = textField.text,
                  let swiftRange = Range(range, in: current) else { return true }
            return current.replacingCharacters(in: swiftRange, with: string).count <= parent.maximumLength
        }

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
