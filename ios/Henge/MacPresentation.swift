import Foundation
import QuartzCore

/// A running machine as an external display shows it: the session's router and the guest's screen
/// shape. One id means one session (its router), whatever the aspect.
struct MacPresentation: Identifiable {
    let display: DisplayRouter
    let aspect: CGFloat

    var id: ObjectIdentifier { ObjectIdentifier(display) }

    /// Takes one external surface off the router.
    @MainActor func release(_ surface: UUID) { display.disconnect(surface) }
}
