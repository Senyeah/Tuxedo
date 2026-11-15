import Foundation

/// Compatibility mapping for GameController physical mice/trackpads only.
/// Guest button IDs are 0 = left, 1 = right, 2 = middle; touch controls retain those IDs.
/// State is per device: with AssistiveTouch one click can come from a device that then disconnects.
struct PhysicalMouseButtons {
    static let swapKey = "tux.mouse.swapRightAndMiddle"

    /// Captured when the VM session starts, so a held button's release uses the same mapping.
    let swapsRightAndMiddle: Bool
    private var byDevice: [Int: Set<Int32>] = [:]

    init(swapsRightAndMiddle: Bool) { self.swapsRightAndMiddle = swapsRightAndMiddle }

    /// Guest buttons held by any device.
    var held: Set<Int32> { byDevice.values.reduce(into: []) { $0.formUnion($1) } }

    /// The guest button to send, or nil when another device keeps the guest's state as it is.
    mutating func event(_ physicalButton: Int32, pressed: Bool, device: Int = 0) -> Int32? {
        guard (0...2).contains(physicalButton) else { return nil }
        let guestButton = swapsRightAndMiddle && physicalButton != 0 ? 3 - physicalButton : physicalButton
        let others = heldByOthers(than: device)
        if pressed {
            byDevice[device, default: []].insert(guestButton)
        } else {
            byDevice[device]?.remove(guestButton)
        }
        return others.contains(guestButton) ? nil : guestButton
    }

    /// Release what one device held, except buttons another device still holds.
    mutating func releaseAll(for device: Int) -> [Int32] {
        let mine = byDevice.removeValue(forKey: device) ?? []
        return mine.subtracting(heldByOthers(than: device)).sorted()
    }

    /// Release all mapped buttons when the VM input session ends.
    mutating func releaseAll() -> [Int32] {
        let releases = held.sorted()
        byDevice.removeAll()
        return releases
    }

    private func heldByOthers(than device: Int) -> Set<Int32> {
        byDevice.filter { $0.key != device }.values.reduce(into: []) { $0.formUnion($1) }
    }
}
