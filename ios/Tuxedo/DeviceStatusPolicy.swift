// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The rules DeviceStatus follows, without UIKit, so they can be tested on the Mac.
enum DeviceStatusPolicy {
    /// UIDevice.batteryLevel (0 to 1, or -1 when unknown) as the engine's 0-100 or -1.
    static func batteryLevel(_ level: Float) -> Int32 {
        guard level >= 0 else { return -1 }
        return Int32(min(100, (level * 100).rounded()))
    }

    /// UIDevice.BatteryState's raw value as the engine's state; anything else is unknown.
    static func batteryState(_ raw: Int) -> Int32 { (0...3).contains(raw) ? Int32(raw) : 0 }

    /// The guest's brightness goes to the phone's screen only while the picture is on it and the app is in front.
    static func appliesBrightness(pictureOnPhone: Bool, appActive: Bool) -> Bool { pictureOnPhone && appActive }

    /// The volume the guest sees: while the volume buttons are clicks, the system volume is pinned, and the guest gets
    /// the one that comes back when they stop.
    static func guestVolume(system: Float, pinned: Bool, restored: Float) -> Double { Double(pinned ? restored : system) }

    /// The user's brightness before the guest's first change, put back when the session ends or the app goes away.
    struct BrightnessRestore {
        private(set) var saved: Double?

        /// Before the guest sets the screen: keeps the user's level the first time only.
        mutating func willApply(current: Double) {
            if saved == nil { saved = current }
        }

        /// The level to put back, once.
        mutating func takeRestore() -> Double? {
            defer { saved = nil }
            return saved
        }
    }

    /// At most one log line per interval for a value that changes often (auto-brightness).
    struct LogLimit {
        let interval: TimeInterval
        private var last = Date.distantPast

        init(interval: TimeInterval) { self.interval = interval }

        mutating func allows(at now: Date) -> Bool {
            guard now.timeIntervalSince(last) >= interval else { return false }
            last = now
            return true
        }
    }
}
