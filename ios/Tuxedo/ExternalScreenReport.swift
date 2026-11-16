// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit

/// The external screen now connected, and the guest's size on it, for Settings.
@MainActor
final class ExternalScreenReport: ObservableObject {
    static let shared = ExternalScreenReport()

    @Published private(set) var facts: ExternalScreenFacts?
    /// The running machine's guest size while it is on an external screen, with its scale.
    @Published var guest: (mode: GuestMode, scale: Double)?
    private var observers: [NSObjectProtocol] = []

    private init() {
        for name in [UIScreen.didConnectNotification, UIScreen.didDisconnectNotification, UIScreen.modeDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        let screen = UIScreen.screens.first { $0 !== UIScreen.main }
        let next = screen.map { s -> ExternalScreenFacts in
            let mode = s.currentMode?.size ?? s.nativeBounds.size
            let inset = s.overscanCompensationInsets
            return ExternalScreenFacts(mode: mode.width < 1 ? s.nativeBounds.size : mode, native: s.nativeBounds.size,
                                       hz: s.maximumFramesPerSecond, modes: s.availableModes.map(\.size),
                                       overscan: DisplayInsets(top: inset.top, left: inset.left, bottom: inset.bottom, right: inset.right))
        }
        if facts != next { facts = next }
    }
}
