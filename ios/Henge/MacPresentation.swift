import Foundation
import QuartzCore

/// A running Mac as an external display shows it: the session's router and the Mac's screen
/// shape. One id means one Mac session (its router), whatever the aspect.
struct MacPresentation: Identifiable {
    let display: DisplayRouter
    let aspect: CGFloat
    /// What runs: a Linux machine says it is starting on the external screen until it draws.
    var isLinux = false

    var id: ObjectIdentifier { ObjectIdentifier(display) }

    /// Takes one external surface off the router.
    @MainActor func release(_ surface: UUID) { display.disconnect(surface) }
}
