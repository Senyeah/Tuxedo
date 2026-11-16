// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

// DeviceStatusPolicy (ios/Tuxedo/DeviceStatusPolicy.swift): what the phone gives a Linux guest, and when the guest's
// sliders reach the phone.
@main
struct DeviceStatusPolicyTests {
    static var failures = 0
    static var checks = 0

    static func check(_ what: String, _ got: some Equatable, _ want: some Equatable) {
        checks += 1
        if "\(got)" != "\(want)" {
            print("FAIL \(what): \(got), expected \(want)")
            failures += 1
        }
    }

    static func main() {
        check("battery: unknown level", DeviceStatusPolicy.batteryLevel(-1), Int32(-1))
        check("battery: 0.87 is 87", DeviceStatusPolicy.batteryLevel(0.87), Int32(87))
        check("battery: rounds", DeviceStatusPolicy.batteryLevel(0.865), Int32(87))
        check("battery: full", DeviceStatusPolicy.batteryLevel(1), Int32(100))
        check("battery: never above 100", DeviceStatusPolicy.batteryLevel(1.2), Int32(100))
        for raw in 0...3 { check("battery: state \(raw) passes", DeviceStatusPolicy.batteryState(raw), Int32(raw)) }
        check("battery: a new state is unknown", DeviceStatusPolicy.batteryState(7), Int32(0))

        check("brightness: on the phone, in front", DeviceStatusPolicy.appliesBrightness(pictureOnPhone: true, appActive: true), true)
        check("brightness: not on an external display", DeviceStatusPolicy.appliesBrightness(pictureOnPhone: false, appActive: true), false)
        check("brightness: not while the app is away", DeviceStatusPolicy.appliesBrightness(pictureOnPhone: true, appActive: false), false)

        check("volume: the system volume", DeviceStatusPolicy.guestVolume(system: 0.3, pinned: false, restored: 0.8), 0.30000001192092896)
        check("volume: the saved one while the buttons are clicks", DeviceStatusPolicy.guestVolume(system: 0.5, pinned: true, restored: 0.8), 0.800000011920929)

        var restore = DeviceStatusPolicy.BrightnessRestore()
        check("restore: nothing to put back at first", restore.takeRestore() == nil, true)
        restore.willApply(current: 0.4)
        restore.willApply(current: 0.9) // the guest's own level, after its first change
        check("restore: the user's level, not the guest's", restore.takeRestore() ?? -1, 0.4)
        check("restore: once", restore.takeRestore() == nil, true)
        restore.willApply(current: 0.6)
        check("restore: a new session saves again", restore.takeRestore() ?? -1, 0.6)

        var limit = DeviceStatusPolicy.LogLimit(interval: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        check("log: the first line", limit.allows(at: t0), true)
        check("log: not again within the interval", limit.allows(at: t0.addingTimeInterval(9)), false)
        check("log: after it", limit.allows(at: t0.addingTimeInterval(10)), true)

        print("device status policy: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
