// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

/// One external display scene (UIResponder makes it main-actor).
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate, ExternalScreen {
    /// Names this display's view to DisplayRouter, so one display going away leaves the others alone.
    let surface = UUID()
    var window: UIWindow?
    private var windowScene: UIWindowScene?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        windowScene = scene
        scene.screen.overscanCompensation = .none // the monitor must not resample the guest again
        let mode = scene.screen.currentMode
        TuxLog.log("display", "external display connected: \(Int(scene.screen.nativeBounds.width))x\(Int(scene.screen.nativeBounds.height)) px, "
                   + "mode \(mode.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "unknown"), "
                   + "scale \(scene.screen.nativeScale), \(scene.screen.maximumFramesPerSecond) Hz")
        LegacyExternalDisplay.shared.connect(self)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        TuxLog.log("display", "external display disconnected")
        LegacyExternalDisplay.shared.disconnect(self)
        windowScene = nil
    }

    func showMachine(_ presentation: MachinePresentation) {
        guard let windowScene else { return }
        let window = self.window ?? UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        window.rootViewController = UIHostingController(rootView: ExternalDisplay(presentation: presentation, surface: surface))
        window.isHidden = false
        self.window = window
        TuxLog.log("display", "the machine is on the external display")
    }

    /// Takes the guest off this display: no window of ours, so iOS mirrors the phone (or the display is gone).
    func stopMachine() {
        guard let window else { return }
        window.rootViewController = nil // lets SwiftUI take the screen view down, which detaches its layer
        window.isHidden = true
        self.window = nil
        TuxLog.log("display", "the machine left the external display")
    }
}
