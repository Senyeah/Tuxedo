import SwiftUI
import UIKit

/// The keyboard's frame, heard from when a Linux session starts. Main thread only.
enum KeyboardFrame {
    private(set) static var memory = KeyboardFrameMemory()
    private static var observers: [NSObjectProtocol] = []

    /// Call before a keyboard can come up; more calls do nothing.
    static func start() {
        guard observers.isEmpty else { return }
        let centre = NotificationCenter.default
        observers = [
            centre.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { willChange($0) },
            centre.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { _ in didHide() },
        ]
    }

    // A probe calls these from its own observers too: the order of two observers is not fixed.
    static func willChange(_ note: Notification) {
        memory.willChange(to: note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)
    }

    static func didHide() { memory.didHide() }
}

/// Lies over the box that holds the Linux picture and reports the keyboard's part of it (KeyboardPanel.fraction).
/// It takes no touches.
struct KeyboardPanelProbe: UIViewRepresentable {
    /// The guest's size: the picture has this shape, centred in the box.
    var guest: CGSize
    /// The box in the session's layout. Only so that a move of the box is an update.
    var frame: CGRect

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ view: Probe, context: Context) {
        view.guest = guest
        DispatchQueue.main.async { view.report() } // after SwiftUI has moved the view
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: UIView {
        var guest = CGSize.zero
        private var observers: [NSObjectProtocol] = []
        private var stopped = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            KeyboardFrame.start()
            let centre = NotificationCenter.default
            observers = [
                centre.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
                    KeyboardFrame.willChange(note)
                    self?.report()
                },
                centre.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
                    KeyboardFrame.didHide()
                    self?.report()
                },
            ]
        }

        required init?(coder: NSCoder) { fatalError("made in code") }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        func report() {
            guard !stopped, let window else {
                henge_share_set_keyboard_height(0)
                return
            }
            let picture = TouchMapping.pictureRect(guest: guest, in: bounds)
            let keyboard = KeyboardFrame.memory.frame // not this view's own: the keyboard can be up before the view is
            let covered = keyboard.isNull ? CGRect.null : convert(keyboard, from: window.screen.coordinateSpace)
            henge_share_set_keyboard_height(KeyboardPanel.fraction(keyboard: covered, picture: picture))
        }

        /// The picture is gone (the console, another screen, the session's end): no keyboard is over it.
        func stop() {
            stopped = true
            henge_share_set_keyboard_height(0)
        }
    }
}
