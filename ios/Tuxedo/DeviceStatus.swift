// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit
import AVFAudio
import MediaPlayer

/// The phone's battery, screen brightness, volume, clock and time zone for a Linux guest (LINUX-PLAN-13), and the
/// guest's own brightness and volume sliders back to the phone. The engine keeps the values for the next machine,
/// so this starts before boot. Main thread only.
final class DeviceStatus: NSObject {
    static let shared = DeviceStatus()

    private var running = false
    private var observers: [NSObjectProtocol] = []
    private var volumeObservation: NSKeyValueObservation?
    private var requests: Task<Void, Never>?
    private var restore = DeviceStatusPolicy.BrightnessRestore()
    private var brightnessLog = DeviceStatusPolicy.LogLimit(interval: 10)
    private var pictureOnPhone: () -> Bool = { true }

    /// The screen the session's window is on (UIScreen.main is deprecated).
    private var screen: UIScreen? { SystemVolume.keyWindow()?.windowScene?.screen }

    func start(pictureOnPhone: @escaping () -> Bool) {
        guard !running else { return }
        running = true
        self.pictureOnPhone = pictureOnPhone
        UIDevice.current.isBatteryMonitoringEnabled = true
        SystemVolume.shared.attach() // its slider is there by the time the guest asks
        // outputVolume is current, and its KVO fires, only in an active session; the category (TuxApp) stays as it is
        try? AVAudioSession.sharedInstance().setActive(true)
        sendBattery()
        sendBrightness()
        sendVolume()
        sendTimeZone()
        let centre = NotificationCenter.default
        let follow: [(Notification.Name, (DeviceStatus) -> Void)] = [
            (UIDevice.batteryLevelDidChangeNotification, { $0.sendBattery() }),
            (UIDevice.batteryStateDidChangeNotification, { $0.sendBattery() }),
            (UIScreen.brightnessDidChangeNotification, { $0.sendBrightness() }),
            (.NSSystemTimeZoneDidChange, { $0.sendTimeZone() }),
            (.NSSystemClockDidChange, { _ in tux_vm_status_touch() }),
            (UIApplication.significantTimeChangeNotification, { _ in tux_vm_status_touch() }),
        ]
        for (name, body) in follow {
            observers.append(centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if let self { body(self) }
            })
        }
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] _, _ in
            DispatchQueue.main.async { self?.sendVolume() }
        }
        requests = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.takeRequests()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        TuxLog.log("status", "following the battery, brightness, volume and time zone")
    }

    func stop() {
        guard running else { return }
        running = false
        requests?.cancel()
        requests = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        volumeObservation = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
        putBrightnessBack()
        SystemVolume.shared.detach()
    }

    /// The app leaves the foreground: the screen is the user's again.
    func leaveForeground() { putBrightnessBack() }

    private func putBrightnessBack() {
        guard let level = restore.takeRestore(), let screen else { return }
        screen.brightness = CGFloat(level)
        TuxLog.log("status", String(format: "brightness back to the user's %.2f", level))
    }

    // MARK: The phone to the guest

    private func sendBattery() {
        let device = UIDevice.current
        let level = DeviceStatusPolicy.batteryLevel(device.batteryLevel)
        let state = DeviceStatusPolicy.batteryState(device.batteryState.rawValue)
        tux_vm_set_battery(level, state)
        TuxLog.log("status", "battery \(level) % state \(state)")
    }

    private func sendBrightness() {
        guard let screen else { return }
        let level = Double(screen.brightness)
        tux_vm_set_brightness(level)
        if brightnessLog.allows(at: Date()) { TuxLog.log("status", String(format: "brightness %.2f", level)) }
    }

    private func sendVolume() {
        let clicks = VolumeClicks.shared
        let level = DeviceStatusPolicy.guestVolume(system: AVAudioSession.sharedInstance().outputVolume,
                                                   pinned: clicks.pinsVolume, restored: clicks.volumeToRestore)
        tux_vm_set_volume(level)
    }

    private func sendTimeZone() {
        NSTimeZone.resetSystemTimeZone()
        let name = TimeZone.current.identifier
        let rc = tux_vm_set_timezone(name)
        TuxLog.log("status", rc == 0 ? "time zone \(name)" : "time zone \(name) not passed on")
    }

    // MARK: The guest's sliders to the phone

    private func takeRequests() {
        var level = 0.0
        var muted: Int32 = 0
        if tux_vm_take_brightness_request(&level) != 0 {
            let active = UIApplication.shared.applicationState == .active
            if DeviceStatusPolicy.appliesBrightness(pictureOnPhone: pictureOnPhone(), appActive: active), let screen {
                restore.willApply(current: Double(screen.brightness))
                screen.brightness = CGFloat(level)
                TuxLog.log("status", String(format: "the guest set the brightness to %.2f", level))
            } else {
                TuxLog.log("status", String(format: "the guest's brightness %.2f not applied: the picture is elsewhere or the app is away", level))
            }
        }
        if tux_vm_take_volume_request(&level, &muted) != 0 {
            let clicks = VolumeClicks.shared
            if clicks.pinsVolume {
                clicks.volumeToRestore = Float(level) // the buttons stay clicks; this is the level they give back
            } else {
                SystemVolume.shared.set(Float(level))
            }
            TuxLog.log("status", String(format: "the guest set the volume to %.2f%@", level, muted != 0 ? " (muted in the guest)" : ""))
        }
    }
}

/// The system volume, which an app can set only through MPVolumeView's slider. VolumeClicks and DeviceStatus share
/// one view, off screen in the key window, while either needs it. Main thread only.
final class SystemVolume {
    static let shared = SystemVolume()
    private var view: MPVolumeView?
    private var users = 0

    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    func attach() {
        users += 1
        guard view == nil else { return }
        let v = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        v.showsRouteButton = false
        v.isUserInteractionEnabled = false
        Self.keyWindow()?.addSubview(v)
        view = v
    }

    func detach() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        view?.removeFromSuperview()
        view = nil
    }

    /// The slider can take a run-loop turn to appear: one more try then.
    func set(_ value: Float) {
        if let view, let slider = Self.slider(in: view) {
            slider.value = value
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let view = self?.view, let slider = Self.slider(in: view) else { return }
            slider.value = value
        }
    }

    private static func slider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for sub in view.subviews { if let slider = slider(in: sub) { return slider } }
        return nil
    }
}
