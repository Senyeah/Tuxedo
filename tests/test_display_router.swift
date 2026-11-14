import Foundation
import QuartzCore

/// What the engine was last told to draw into.
nonisolated(unsafe) var engineLayer: UnsafeMutableRawPointer?

@_cdecl("henge_vm_set_display_layer")
func recordDisplayLayer(_ layer: UnsafeMutableRawPointer?) { engineLayer = layer }

@main
struct DisplayRouterTests {
    @MainActor static func main() {
        let phoneLayer = CAMetalLayer(), monitorLayer = CAMetalLayer()
        let phone = UUID(), monitor = UUID()
        let router = DisplayRouter()
        func engineShows(_ layer: CAMetalLayer) -> Bool { engineLayer == Unmanaged.passUnretained(layer).toOpaque() }

        router.connect(phone, layer: phoneLayer, role: .device)
        router.connect(monitor, layer: monitorLayer, role: .external)
        precondition(engineShows(monitorLayer) && router.isExternal)

        // Two monitors (USB-C and AirPlay): the later one shows the guest. Disconnecting one
        // monitor's surface leaves the other showing it, not the phone.
        let airPlayLayer = CAMetalLayer(), airPlay = UUID()
        router.connect(airPlay, layer: airPlayLayer, role: .external)
        precondition(engineShows(airPlayLayer))
        router.disconnect(airPlay)
        precondition(engineShows(monitorLayer) && router.isExternal)

        // The last monitor going gives the guest back to the phone, and a late repeat changes nothing.
        router.disconnect(monitor)
        precondition(engineShows(phoneLayer) && !router.isExternal)
        router.disconnect(monitor)
        precondition(engineShows(phoneLayer) && !router.isExternal)

        // The external screen's pixels are reported while it shows the guest, and clear when the phone gets it back.
        let tv = CGSize(width: 3840, height: 2160), small = CGSize(width: 1920, height: 1080)
        precondition(router.externalPixels == nil)
        router.connect(monitor, layer: monitorLayer, role: .external, screenPixels: tv)
        precondition(router.externalPixels == tv)
        router.connect(airPlay, layer: airPlayLayer, role: .external, screenPixels: small)
        precondition(router.externalPixels == small)
        router.disconnect(airPlay)
        precondition(router.externalPixels == tv)
        router.connect(UUID(), layer: CAMetalLayer(), role: .device)
        precondition(router.externalPixels == tv)
        router.disconnect(monitor)
        precondition(router.externalPixels == nil && !router.isExternal)
        print("Display router: all checks passed")
    }
}
