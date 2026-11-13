import SwiftUI
import UIKit

/// An invisible text input with a 56 pt row above the keyboard, as Henge has
/// (ios/Henge/Input.swift:102-107). The row's last key hides the keyboard.
final class LabKeyboardView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onShown: ((Bool) -> Void)?

    private lazy var row: UIHostingController<LabKeyRow> = {
        let host = UIHostingController(rootView: LabKeyRow(hide: { [weak self] in self?.hide() }))
        host.sizingOptions = []
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 56)
        host.view.autoresizingMask = .flexibleWidth
        return host
    }()

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { row.view }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark

    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onText?("\u{8}") }

    func show() {
        becomeFirstResponder()
        onShown?(true)
    }

    func hide() {
        resignFirstResponder()
        onShown?(false)
    }

    var shown: Bool { isFirstResponder }
}

/// The row above the keyboard: inert keys like Henge's, and the hide key.
struct LabKeyRow: View {
    let hide: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(["esc", "tab", "⌃", "⌥", "⌘", "←", "↑", "↓", "→"], id: \.self) { k in
                Text(k)
                    .font(.system(size: k.count > 1 ? 11 : 15, weight: .semibold))
                    .foregroundStyle(Color(white: 0.95))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 35 / 255, green: 38 / 255, blue: 47 / 255), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            Button(action: hide) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.95))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 35 / 255, green: 38 / 255, blue: 47 / 255), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .accessibilityLabel("Hide keyboard")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(height: 56)
    }
}

struct LabKeyboard: UIViewRepresentable {
    let view: LabKeyboardView
    func makeUIView(context: Context) -> LabKeyboardView { view }
    func updateUIView(_ v: LabKeyboardView, context: Context) {}
}
