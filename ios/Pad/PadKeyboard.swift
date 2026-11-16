// SPDX-License-Identifier: GPL-2.0-or-later
import QuartzCore
import UIKit

/// Follows the on-screen keyboard: a tracker view pinned to the host's keyboard layout guide.
/// The system moves the guide with the keyboard's own duration and curve; each frame reads the
/// tracker's presentation frame, so the pad's edge is at the keyboard's top in each frame.
final class PadKeyboard {
    private let tracker = UIView()
    private weak var host: UIView?
    /// The cover when the keyboard is fully up. It stays while the keyboard goes down.
    private(set) var fullCover = 0.0
    private var movingUntil: CFTimeInterval = 0
    /// A keyboard notification arrived: going up (true) or down.
    var onChange: ((Bool) -> Void)?

    init(host: UIView) {
        self.host = host
        tracker.isUserInteractionEnabled = false
        tracker.alpha = 0
        tracker.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(tracker)
        let guide = host.keyboardLayoutGuide
        guide.followsUndockedKeyboard = false
        guide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            tracker.topAnchor.constraint(equalTo: guide.topAnchor),
            tracker.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            tracker.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            tracker.widthAnchor.constraint(equalToConstant: 1),
        ])
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(change(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(change(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// The keyboard's cover from the host's bottom now, in points.
    var cover: Double {
        guard let host else { return 0 }
        let top = tracker.layer.presentation()?.frame.minY ?? tracker.frame.minY
        return PadLayout.cover(guideTop: Double(top), viewHeight: Double(host.bounds.height), docked: true)
    }

    var moving: Bool { CACurrentMediaTime() < movingUntil }
    var state: PadLayout.Keyboard { .init(cover: cover, fullCover: fullCover) }

    @objc private func change(_ n: Notification) {
        guard let host, host.window != nil else { return }
        let info = n.userInfo ?? [:]
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7
        let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        let screen = host.window?.screen.coordinateSpace
        let local = screen.map { host.convert(end, from: $0) } ?? end
        // Docked: the keyboard's frame reaches the bottom of the host. A floating one does not.
        let docked = local.height > 0 && local.maxY >= host.bounds.maxY - 1 && n.name != UIResponder.keyboardWillHideNotification
        let endCover = docked ? max(0, Double(host.bounds.maxY - local.minY)) : 0
        let up = endCover > fullCover * 0.5 && endCover > 0
        if endCover > 0 { fullCover = endCover }
        movingUntil = CACurrentMediaTime() + max(duration, 0.1) + 0.1
        UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: UInt(curve) << 16), .beginFromCurrentState]) {
            host.layoutIfNeeded()
        }
        onChange?(up)
    }
}
