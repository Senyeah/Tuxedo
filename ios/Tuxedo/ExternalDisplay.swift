import SwiftUI

/// The accessory only presents the existing guest's pixels. It never owns or
/// starts a VM, and hardware input continues through the phone's SessionView.
struct ExternalDisplay: View {
    let presentation: MachinePresentation
    /// The id this display's view connects to the router under; a display scene passes its own.
    var surface = UUID()

    var body: some View {
        GeometryReader { geometry in
            let aspect = presentation.aspect
            let width = min(geometry.size.width, geometry.size.height * aspect)
            BootDisplay(display: presentation.display, role: .external, surface: surface)
                .frame(width: width, height: width / aspect)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay { GuestHidden(display: presentation.display) }
        .background(.black)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .preferredColorScheme(.dark)
    }
}

/// Black over the guest while the session hides it (Face ID): the external screen keeps the last frame otherwise.
private struct GuestHidden: View {
    @ObservedObject var display: DisplayRouter

    var body: some View {
        if display.guestHidden { Color.black.ignoresSafeArea() }
    }
}

/// Puts the session's guest on an external display. iOS 27 delivers that scene only to this
/// accessory; earlier iOS connects it to ExternalDisplaySceneDelegate (LegacyExternalDisplay),
/// which is told about the session either way and acts only where iOS gives it scenes.
struct ExternalDisplayModifier: ViewModifier {
    let presentation: MachinePresentation

    @ViewBuilder
    func body(content: Content) -> some View {
        let session = content
            .onAppear { LegacyExternalDisplay.shared.begin(presentation) }
            .onDisappear { LegacyExternalDisplay.shared.end(presentation) }
        if #available(iOS 27.0, *) { // the compiler requires this to call the iOS 27 sceneAccessory API
            session.sceneAccessory {
                ExternalNonInteractiveAccessory {
                    ExternalDisplay(presentation: presentation)
                }
            }
        } else {
            session
        }
    }
}
