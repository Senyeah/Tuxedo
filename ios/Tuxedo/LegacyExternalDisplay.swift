import Foundation

/// One external display as LegacyExternalDisplay drives it: ExternalDisplaySceneDelegate in the
/// app, a fake in tests.
@MainActor
protocol ExternalScreen: AnyObject {
    /// The id this screen's view connects to DisplayRouter under.
    var surface: UUID { get }
    func showMachine(_ presentation: MachinePresentation)
    func stopMachine()
}

/// Before iOS 27, a connected display (USB-C cable or AirPlay) arrives as a
/// `windowExternalDisplayNonInteractive` scene that iOS connects to ExternalDisplaySceneDelegate
/// because Info.plist's scene manifest declares that role with that class (without the entry the
/// display just mirrors the phone and the app hears nothing). This shows the running machine on those
/// scenes as ExternalScreenPlan decides; a screen not showing it gets no window of ours, so iOS
/// mirrors the phone there. iOS 27 offers the scene only to the accessory
/// ExternalDisplayModifier registers, so here it never sees one.
@MainActor
final class LegacyExternalDisplay {
    static let shared = LegacyExternalDisplay()

    /// Whether the app delegate may answer for external display scenes, should UIKit ask it: not
    /// from iOS 27, where that scene is the accessory's.
    nonisolated static var offeredToAppDelegate: Bool {
        if #available(iOS 27.0, *) { return false } else { return true }
    }

    private var plan = ExternalScreenPlan<MachinePresentation>()
    private var screens: [UUID: ExternalScreen] = [:]

    /// A session appeared: its guest goes to every connected display.
    func begin(_ presentation: MachinePresentation) {
        apply(plan.begin(presentation))
    }

    /// A session went away: its displays go back to mirroring.
    func end(_ presentation: MachinePresentation) {
        apply(plan.end(presentation))
    }

    func connect(_ screen: ExternalScreen) {
        screens[screen.surface] = screen
        apply(plan.connect(screen.surface))
    }

    func disconnect(_ screen: ExternalScreen) {
        apply(plan.disconnect(screen.surface))
        screens.removeValue(forKey: screen.surface)
    }

    private func apply(_ changes: [ExternalScreenPlan<MachinePresentation>.Change]) {
        for change in changes {
            switch change {
            case .showMachine(let surface, let presentation):
                screens[surface]?.showMachine(presentation)
            case .stopMachine(let surface, let presentation):
                screens[surface]?.stopMachine()
                // The surface's own detach may never come once its window is gone.
                presentation.release(surface)
            }
        }
    }
}
