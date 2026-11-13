import SwiftUI
import UIKit

/// The Linux picture as a touchscreen (LINUX-PLAN-12): each finger is a contact on the guest's virtio
/// touchscreen, at its place in the picture. Taps, holds and gestures are the guest's to make.
/// Only fingers count: a real trackpad or mouse goes through HardwareMouse. Four fingers still show
/// the session's hidden controls, as on the trackpad.
struct TouchScreen: UIViewRepresentable {
    /// The guest picture, in this view's coordinates.
    var guestRect: CGRect

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) { view.picture = guestRect }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.cancelAll() }

    final class Surface: UIView, UIPointerInteractionDelegate {
        private static let tapTime: TimeInterval = 0.6
        private static let tapTravel: CGFloat = 24

        var picture: CGRect = .zero
        private var slots = TouchSlots<ObjectIdentifier>()
        private var down = Set<ObjectIdentifier>() /* every finger on the view, sent or not */
        private var revealing = false /* four fingers: nothing goes to the guest until all lift */
        private var started = Date()
        private var travelled: CGFloat = 0
        private var contactsLogged = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            addInteraction(UIPointerInteraction(delegate: self))
        }

        required init?(coder: NSCoder) { fatalError("made in code") }

        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

        /// UIKit does not always end a view's touches when it leaves the window.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window == nil else { return }
            cancelAll()
            down.removeAll()
            revealing = false
        }

        func cancelAll() {
            guard !slots.isEmpty else { return }
            _ = slots.releaseAll()
            henge_vm_screen_touch_cancel()
        }

        private func fingers(_ touches: Set<UITouch>) -> [UITouch] { touches.filter { $0.type != .indirectPointer } }

        private func send(_ slot: Int, _ phase: Int32, _ t: UITouch) {
            let g = TouchMapping.position(t.preciseLocation(in: self), in: picture)
            henge_vm_screen_touch(Int32(slot), phase, Int32(g.x), Int32(g.y))
            if phase == 0 && contactsLogged < 12 {
                contactsLogged += 1
                HengeLog.log("input", "touch: slot \(slot) down at \(g.x),\(g.y)")
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let new = fingers(touches)
            guard !new.isEmpty else { return }
            if down.isEmpty {
                started = Date()
                travelled = 0
            }
            down.formUnion(new.map(ObjectIdentifier.init))
            if down.count >= 4 && !revealing {
                revealing = true
                cancelAll()
            }
            guard !revealing else { return }
            var sent = false
            for t in new {
                /* A touch on the border stays the app's. */
                guard TouchMapping.startsInside(t.preciseLocation(in: self), picture), let slot = slots.take(ObjectIdentifier(t)) else { continue }
                send(slot, 0, t)
                sent = true
            }
            if sent { henge_vm_screen_touch_frame() }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            var moved = false
            for t in fingers(touches) {
                let now = t.location(in: self), before = t.previousLocation(in: self)
                travelled += abs(now.x - before.x) + abs(now.y - before.y)
                guard let slot = slots.slot(ObjectIdentifier(t)) else { continue }
                send(slot, 1, t)
                moved = true
            }
            /* One frame per event: fingers move together. */
            if moved { henge_vm_screen_touch_frame() }
        }

        /* Linux has no cancel for one contact: a cancelled touch lifts. */
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

        private func lift(_ touches: Set<UITouch>) {
            var lifted = false
            for t in fingers(touches) {
                let id = ObjectIdentifier(t)
                down.remove(id)
                guard let slot = slots.release(id) else { continue }
                henge_vm_screen_touch(Int32(slot), 2, 0, 0)
                lifted = true
            }
            if lifted { henge_vm_screen_touch_frame() }
            guard down.isEmpty else { return }
            if revealing {
                revealing = false
                if Date().timeIntervalSince(started) < Self.tapTime, travelled < Self.tapTravel {
                    NotificationCenter.default.post(name: Trackpad.revealTap, object: nil)
                }
            }
            StickyKeys.shared.releaseAll()
        }
    }
}
