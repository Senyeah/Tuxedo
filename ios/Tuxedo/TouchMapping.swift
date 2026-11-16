// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics

/// Touches on the Linux picture (LINUX-PLAN-12): a point becomes a fraction of the guest picture, sent as 0...32767
/// on each axis. Rotation, resolution, scale and zoom then need nothing in the guest. No UIKit, so tests run on macOS.
enum TouchMapping {
    static let maxValue = 32767
    static let slotCount = 10

    /// The guest picture inside `frame` as the layer's resizeAspect draws it: its own aspect, centred.
    static func pictureRect(guest: CGSize, in frame: CGRect) -> CGRect {
        guard guest.width > 0, guest.height > 0, frame.width > 0, frame.height > 0 else { return frame }
        let k = min(frame.width / guest.width, frame.height / guest.height)
        let w = guest.width * k, h = guest.height * k
        return CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
    }

    /// Only a touch that starts on the picture goes to the guest; one on the border stays the app's.
    static func startsInside(_ p: CGPoint, _ picture: CGRect) -> Bool {
        picture.width > 0 && picture.height > 0 && p.x >= picture.minX && p.x <= picture.maxX && p.y >= picture.minY && p.y <= picture.maxY
    }

    /// Guest units; a touch that leaves the picture stays on its edge.
    static func position(_ p: CGPoint, in picture: CGRect) -> (x: Int, y: Int) {
        guard picture.width > 0, picture.height > 0 else { return (0, 0) }
        let u = min(max((p.x - picture.minX) / picture.width, 0), 1)
        let v = min(max((p.y - picture.minY) / picture.height, 0), 1)
        return (Int((u * CGFloat(maxValue)).rounded()), Int((v * CGFloat(maxValue)).rounded()))
    }
}

/// Which guest slot each touch holds: the lowest free one, freed at the lift.
struct TouchSlots<Key: Hashable> {
    private(set) var held: [Key: Int] = [:]

    var isEmpty: Bool { held.isEmpty }

    func slot(_ key: Key) -> Int? { held[key] }

    /// nil when all ten are taken, or the key has one already.
    mutating func take(_ key: Key) -> Int? {
        guard held[key] == nil else { return nil }
        let used = Set(held.values)
        guard let free = (0..<TouchMapping.slotCount).first(where: { !used.contains($0) }) else { return nil }
        held[key] = free
        return free
    }

    mutating func release(_ key: Key) -> Int? { held.removeValue(forKey: key) }

    /// Every slot, lowest first; the table is empty after.
    mutating func releaseAll() -> [Int] {
        defer { held.removeAll() }
        return held.values.sorted()
    }
}
