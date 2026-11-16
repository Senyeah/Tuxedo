// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import UIKit

/// Testing a build on a phone nobody is holding. Tuxedo follows Documents/tux-autopilot.txt when it is
/// launched with TUX_AUTOPILOT set, as in
///   xcrun devicectl device process launch -e '{"TUX_AUTOPILOT":"1"}' --device ID BUNDLE
/// or, for a launch by hand (a locked phone driven through iPhone Mirroring), once: at launch
/// Documents/tux-autopilot-once.txt is renamed to tux-autopilot.txt and followed, so the next
/// launch runs nothing. Put the files there with devicectl device copy to. One command per line,
/// picking up lines added later while it runs:
///   start [NAME]       start that machine (the one used last without a name) once JIT is on
///   wait SECONDS
///   type TEXT          typed into the guest's keyboard (the log shows only how long it is)
///   console TEXT       a line typed into a Linux machine's console, with Return (the log shows only how long it is)
///   console-wait SECONDS TEXT   wait until TEXT is in the console's newest output, or SECONDS pass (the log says which)
///   console-tail N     the last N characters of the console's newest output, into the log (raw guest text: keep tux.log private)
///   key CODE           a Linux key code (28 is Return, 1 is Escape)
///   move X Y, click X Y  the pointer to a spot on the guest's screen (its pixels), and a click there
///   pointer            where the pointer is now, into the log
///   knob NAME VALUE    a translation knob (core/machine.h)
///   cpus N             the CPUs setting (1-6) for the next machine started; it stays, so set it back afterwards
///   env NAME [VALUE]   set (or unset) an engine environment setting for the next machine started
///   balloon MB         ask the guest for that much of its memory back (HV_BALLOON set), log what it gave
///   linux-catalogue URL   set the Linux catalogue URL and load it
///   linux-download ID  download that catalogue entry and wait; linux-delete ID removes it
///   linux-install ID NAME DISK_GB RAM_MB keep|delete  download, unpack and list a machine, then wait
///   snap [NAME]        the guest's screen (1920x1080) into Documents/NAME.jpg (snap.jpg)
///   log TEXT           a marker in tux.log
///   details [forwards] open the session's Details (and its Port Forwards page), for a screenshot
///   additions-demo [STEP]  the Tuxedo Additions wizard over the machine list, with a sample guest and no machine
///                      (STEP: account opens it as the account prompt does; "switch" opens the Desktop step of a guest
///                      that has labwc and Plasma installed), for a screenshot
///   stop               stop the machine
///   exit               quit Tuxedo
/// Each command is written to tux.log as it runs, so the log has the timeline.
/// TUX_AUTOPILOT in the launch environment (not the once file) also skips a Linux machine's Face ID check
/// (SessionGate). The wallet stays locked unless TUX_AUTOPILOT_WALLET=unlocked is in the launch environment too.
enum Autopilot {
    static let details = Notification.Name("tux.autopilot.details")
    static let additionsDemo = Notification.Name("tux.autopilot.additions-demo")
    private static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    /// Launched for testing: by environment, or by a one-time file (used up here).
    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["TUX_AUTOPILOT"] != nil { return true }
        let once = docs.appendingPathComponent("tux-autopilot-once.txt"), plan = docs.appendingPathComponent("tux-autopilot.txt")
        guard FileManager.default.fileExists(atPath: once.path) else { return false }
        try? FileManager.default.removeItem(at: plan)
        return (try? FileManager.default.moveItem(at: once, to: plan)) != nil
    }()

    @MainActor static func run(start: @escaping (VirtualMachine) -> Void) async {
        guard enabled else { return }
        let url = docs.appendingPathComponent("tux-autopilot.txt")
        TuxLog.log("autopilot", "following \(url.lastPathComponent)")
        var done = 0 // lines already run
        while !Task.isCancelled {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var lines = text.components(separatedBy: "\n")
            lines.removeLast() // only whole lines: the last piece has no newline yet
            if lines.count < done { done = 0 } // a new file
            while done < lines.count, !Task.isCancelled {
                let line = lines[done].trimmingCharacters(in: .whitespaces)
                done += 1
                if line.isEmpty || line.hasPrefix("#") { continue }
                /* What is typed may be a password: the log gets its length only. */
                let typed = ["type ", "console "].first { line.hasPrefix($0) }
                TuxLog.log("autopilot", typed.map { "\($0)(\(line.count - $0.count) characters)" } ?? line)
                await perform(line, start: start)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    @MainActor private static func perform(_ line: String, start: (VirtualMachine) -> Void) async {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "start":
            for _ in 0..<240 where !JITBootstrap.ready { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard JITBootstrap.ready else { TuxLog.log("autopilot", "JIT is not on; not starting a machine"); return }
            let all: [VirtualMachine] = Machines.shared.all
            var machine: VirtualMachine?
            if arg.isEmpty {
                machine = all.max { a, b in (a.lastUsed ?? a.added) < (b.lastUsed ?? b.added) }
            } else {
                machine = all.first { $0.name.lowercased() == arg.lowercased() }
            }
            guard let machine else {
                TuxLog.log("autopilot", "no machine called \(arg); there are \(all.map(\.name))")
                return
            }
            start(machine)
        case "wait":
            try? await Task.sleep(nanoseconds: UInt64((Double(arg) ?? 0) * 1e9))
        case "type":
            await Keys.typeSlowly(arg)
        case "console":
            let bytes = Array((arg + "\r").utf8)
            bytes.withUnsafeBufferPointer { tux_vm_console_write($0.baseAddress, $0.count) }
        case "console-wait": // "console-wait 60 login:": the time limit first, as the text may hold spaces
            let w = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard w.count == 2, let seconds = Double(w[0]) else { TuxLog.log("autopilot", "console-wait wants SECONDS TEXT"); return }
            let end = Date().addingTimeInterval(seconds)
            while !Task.isCancelled, !(ConsoleModel.active?.tail.contains(w[1]) ?? false), Date() < end {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            TuxLog.log("autopilot", "console-wait: \(ConsoleModel.active?.tail.contains(w[1]) == true ? "found" : "timed out")")
        case "console-tail": // what a console command printed, for a test that reads the log
            let n = min(max(Int(arg) ?? 400, 1), 4000)
            let text = (ConsoleModel.active?.tail ?? "").suffix(n).replacingOccurrences(of: "\u{1b}", with: "").replacingOccurrences(of: "\r", with: "")
            TuxLog.log("autopilot", "console-tail: " + text.replacingOccurrences(of: "\n", with: " | "))
        case "key":
            if let code = UInt16(arg) { Keys.press(code) }
        case "move", "click": // guest display pixels: nudged there in small steps, as the guest accelerates big ones
            let xy = arg.split(separator: " ").compactMap { Int32($0) }
            guard xy.count == 2 else { TuxLog.log("autopilot", "\(parts[0]) wants X Y"); return }
            var px: Int32 = 0, py: Int32 = 0
            for _ in 0..<1500 {
                guard tux_vm_pointer(&px, &py) == 0 else { break }
                let dx = xy[0] - px, dy = xy[1] - py
                if abs(dx) < 3 && abs(dy) < 3 { break }
                tux_vm_mouse_move(max(-16, min(16, dx)), max(-16, min(16, dy)))
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            if parts[0] == "click" {
                tux_vm_mouse_button(0, 1)
                try? await Task.sleep(nanoseconds: 120_000_000)
                tux_vm_mouse_button(0, 0)
            }
        case "pointer":
            var px: Int32 = 0, py: Int32 = 0
            let rc = tux_vm_pointer(&px, &py)
            TuxLog.log("autopilot", "pointer \(rc == 0 ? "at \(px), \(py)" : "not known yet")")
        case "knob":
            let kv = arg.split(separator: " ")
            if kv.count == 2, let value = Int32(kv[1]) {
                let found = tux_vm_knob(String(kv[0]), value)
                TuxLog.log("autopilot", found != 0 ? "knob \(kv[0]) = \(value)" : "no knob \(kv[0]) (or no machine running)")
            }
        case "linux-catalogue": // "linux-catalogue URL": the catalogue setting, then load it
            UserDefaults.standard.set(arg, forKey: LinuxCatalogue.urlKey)
            await LinuxInstaller.shared.refresh()
            TuxLog.log("autopilot", "catalogue: \(LinuxInstaller.shared.catalogue)")
        case "linux-download", "linux-delete": // "linux-download debian-console": download it (going on from a part), wait for the end
            guard case .loaded(let images) = LinuxInstaller.shared.catalogue, let image = images.first(where: { $0.id == arg }) else {
                TuxLog.log("autopilot", "no catalogue entry \(arg)")
                return
            }
            if parts[0] == "linux-delete" { LinuxInstaller.shared.deleteDownload(image); return }
            LinuxInstaller.shared.reset()
            LinuxInstaller.shared.download(image)
            while LinuxInstaller.shared.busy, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            TuxLog.log("autopilot", "linux-download \(arg): \(LinuxInstaller.shared.phase), \(LinuxInstaller.shared.received) of \(LinuxInstaller.shared.expected) bytes")
        case "linux-install": // "linux-install debian-console Debian 24 2048 delete": the name may hold spaces
            guard case .loaded(let images) = LinuxInstaller.shared.catalogue else { TuxLog.log("autopilot", "no catalogue"); return }
            let w = arg.split(separator: " ").map(String.init)
            guard w.count >= 5, let image = images.first(where: { $0.id == w[0] }), let gb = Int64(w[w.count - 3]),
                  let ram = Int(w[w.count - 2]) else {
                TuxLog.log("autopilot", "linux-install wants ID NAME DISK_GB RAM_MB keep|delete")
                return
            }
            LinuxInstaller.shared.reset()
            LinuxInstaller.shared.install(image, options: .init(name: w[1..<(w.count - 3)].joined(separator: " "), ramMB: ram,
                                                                diskBytes: gb << 30, keepDownload: w[w.count - 1] == "keep"))
            while LinuxInstaller.shared.busy, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            TuxLog.log("autopilot", "linux-install \(w[0]): \(LinuxInstaller.shared.phase)")
        case "snap": // the guest's screen, full size, into Documents/snap.jpg (or NAME.jpg): "snap", "snap safari"
            let name = arg.isEmpty ? "snap" : arg
            let url = docs.appendingPathComponent("\(name).jpg")
            if let image = MachinePreview.capture(width: 1920, height: 1080),
               let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.9), (try? data.write(to: url, options: .atomic)) != nil {
                TuxLog.log("autopilot", "snap \(url.lastPathComponent), \(data.count / 1024) KB")
            } else {
                TuxLog.log("autopilot", "snap: no screen to read")
            }
        case "cpus": // "cpus 2": the CPU count the next machine started gets (the CPUs setting, kept: put it back after a test)
            if let n = Int(arg), (1...6).contains(n) {
                UserDefaults.standard.set(n, forKey: "tux.cpus")
                TuxLog.log("autopilot", "cpus \(n) for the next start")
            } else {
                TuxLog.log("autopilot", "cpus wants 1 to 6")
            }
        case "env": // "env HV_QOS ui": an engine setting read when the next machine starts (one not in tux-env.txt, which wins)
            let kv = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                setenv(kv[0], kv[1], 1)
                TuxLog.log("autopilot", "env \(kv[0])=\(kv[1]) for the next start")
            } else if kv.count == 1 {
                unsetenv(kv[0])
                TuxLog.log("autopilot", "env \(kv[0]) unset")
            }
        case "balloon": // "balloon 2048": ask the guest to hand 2 GB of its memory back (needs HV_BALLOON in tux-env.txt)
            let got = tux_vm_balloon(Int(arg) ?? -1)
            TuxLog.log("autopilot", got < 0 ? "no balloon (set HV_BALLOON in tux-env.txt)" : "balloon: the guest has handed over \(got) MB")
        case "log": // already in the log; the wall clock too, to line it up with things measured elsewhere
            TuxLog.log("autopilot", String(format: "at %.3f", Date().timeIntervalSince1970))
        case "details":
            NotificationCenter.default.post(name: Autopilot.details, object: arg)
        case "additions-demo":
            NotificationCenter.default.post(name: Autopilot.additionsDemo, object: arg)
        case "stop":
            tux_vm_stop()
        case "exit":
            TuxLog.log("autopilot", "quitting")
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(0)
        default:
            TuxLog.log("autopilot", "unknown command")
        }
    }
}

extension TuxAdditions {
    /// The sample guest of additions-demo: the example of docs/guest-additions-design.md, 5.4, and a small catalogue.
    static func demo(switching: Bool = false) -> TuxAdditions {
        let report = switching ? """
        {"n":1,"agent":"1.11.0","protocol":1,"caps":{"installed":{"tux-guest":"1.11.0","tux-va":"1.0.1","tux-ffmpeg":"9.0.2-tux10"},
         "legacy":false,"account":{"name":"sam","uid":1000,"exists":true,"password_set":true,"configured":true,"sudo":true,"autologin":"user"},
         "root":true,"network":true,"desktop":"labwc","desktops":["labwc","plasma"],"ssh":{"installed":false,"enabled":false,"port":22,"password_auth":true},
         "apps":{"git":true},"hostname":"debian","disk_free_mb":9800,"image":"desktop","ips":["10.0.2.15"],"kernel":"6.12.x-arm64-16k"}}
        """ : """
        {"n":1,"agent":"1.11.0","protocol":1,"caps":{"installed":{"tux-guest":"1.10.2","tux-va":"1.0.1","tux-ffmpeg":"9.0.2-tux2"},
         "legacy":false,"account":{"name":"tux","uid":1000,"exists":true,"password_set":false,"configured":false,"sudo":true,"autologin":"root"},
         "root":true,"network":true,"desktop":"none","ssh":{"installed":false,"enabled":false,"port":22,"password_auth":true},
         "apps":{"git":true},"hostname":"debian","disk_free_mb":1800,"image":"console","ips":["10.0.2.15"],"kernel":"6.12.x-arm64-16k"}}
        """
        let actions = """
        {"protocol":1,"desktops":[{"id":"labwc","title":"Tuxedo desktop (labwc)","size_mb":150},{"id":"plasma","title":"KDE Plasma","size_mb":1500},
         {"id":"xfce","title":"Xfce","size_mb":600}],
         "apps":[{"id":"firefox","title":"Firefox","group":"web","size_mb":80},{"id":"chromium","title":"Chromium","group":"web","size_mb":100},
         {"id":"libreoffice","title":"LibreOffice","group":"office","size_mb":400},{"id":"vlc","title":"VLC","group":"media","size_mb":60},
         {"id":"git","title":"git","group":"develop","size_mb":20},{"id":"htop","title":"htop","group":"tools","size_mb":2}],
         "ssh":{"port_min":1,"port_max":65535,"default_port":22}}
        """
        let versions = #"{"additions":"1.11.0+5","packages":{"tux-guest":"1.11.0","tux-va":"1.0.1","tux-ffmpeg":"9.0.2-tux10"}}"#
        return TuxAdditions(demo: (try? JSONDecoder().decode(AdditionsReport.self, from: Data(report.utf8))) ?? AdditionsReport(),
                            versions: AdditionsVersions.decode(Data(versions.utf8)), catalogue: AdditionsCatalogue.decode(Data(actions.utf8)))
    }
}
