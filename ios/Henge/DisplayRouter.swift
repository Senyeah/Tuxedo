import SwiftUI
import QuartzCore

/// Owned by SessionView, and shared with its display accessory. Only one layer
/// receives frames; the phone's input views stay alive when the monitor takes over.
@MainActor
final class DisplayRouter: ObservableObject {
    @Published private(set) var isExternal = false
    /// The pixels of the external screen that shows the guest; nil on the phone or when the screen did not say.
    @Published private(set) var externalPixels: CGSize?
    /// The session hides the guest (SessionGate.blanksExternal): every external screen shows black.
    @Published var guestHidden = false

    private var targets = DisplayTargetSelection()
    private var layers: [UUID: CAMetalLayer] = [:]
    private var screens: [UUID: CGSize] = [:]
    private var selected: UUID?

    func connect(_ id: UUID, layer: CAMetalLayer, role: DisplayTargetSelection.Role, screenPixels: CGSize? = nil) {
        layers[id] = layer
        screens[id] = screenPixels
        targets.connect(id, role: role)
        updateTarget()
    }

    func disconnect(_ id: UUID) {
        targets.disconnect(id)
        updateTarget()
        layers.removeValue(forKey: id)
        screens.removeValue(forKey: id)
    }

    /// Re-present the latest frame after layout or a return from the background,
    /// even when the guest is idle and isn't submitting another frame.
    func refresh(_ id: UUID? = nil) {
        guard id == nil || id == selected else { return }
        sendTarget()
    }

    private func updateTarget() {
        let next = targets.selected
        if next != selected {
            selected = next
            sendTarget()
        }
        if isExternal != targets.isExternal { isExternal = targets.isExternal }
        let pixels = targets.isExternal ? selected.flatMap { screens[$0] } : nil
        if externalPixels != pixels { externalPixels = pixels }
    }

    private func sendTarget() {
        let layer = selected.flatMap { layers[$0] }
        henge_vm_set_display_layer(layer.map { Unmanaged.passUnretained($0).toOpaque() })
    }
}
