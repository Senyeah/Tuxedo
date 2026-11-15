import Foundation

// Tuxedo Additions in the app (ios/Tuxedo/Additions*.swift, docs/guest-additions-design.md): version order, the
// checks on what a person types, the job JSON, the replay of the agent's events, the wizard's rules, the account
// prompt, the saved report and the reserved folder name. Pure: no UIKit, no engine.
@main
struct AdditionsPolicyTests {
    static var failures = 0

    static func check(_ what: String, _ ok: Bool) {
        if !ok {
            print("FAIL \(what)")
            failures += 1
        }
    }

    static func main() throws {
        versions()
        validators()
        try job()
        try events()
        jobEnds()
        try catalogueAndVersions()
        wizard()
        passwordHygiene()
        trigger()
        try savedReport()
        reservedFolder()
        if failures > 0 { exit(1) }
        print("additions policy: ok")
    }

    // MARK: Fixtures

    static let reportJSON = """
    {"t":"report","n":3,"agent":"1.11.0+5","protocol":1,"caps":
     {"installed":{"tux-guest":"1.10.2","tux-va":"1.0.1","tux-ffmpeg":"9.0.2-tux2","tux-codec-dkms":null},
      "legacy":false,
      "account":{"name":"tux","uid":1000,"exists":true,"password_set":false,"configured":false,"sudo":true,"autologin":"root"},
      "root":true,"network":true,"desktop":"none",
      "ssh":{"installed":false,"enabled":false,"port":22,"password_auth":true},
      "apps":{"firefox":false,"git":true},"hostname":"debian","disk_free_mb":1800,"image":"console",
      "ips":["10.0.2.15"],"kernel":"6.12.x-arm64-16k"}}
    """

    static let actionsJSON = """
    {"protocol":1,
     "desktops":[{"id":"labwc","title":"Tuxedo desktop (labwc)","packages":["labwc"],"size_mb":150,"files":"desktop-labwc"},
                 {"id":"plasma","title":"KDE Plasma","packages":["kde-plasma-desktop"],"size_mb":1500},
                 {"id":"xfce","title":"Xfce","packages":["xfce4"],"size_mb":600}],
     "apps":[{"id":"firefox","title":"Firefox","group":"web","packages":["firefox-esr"],"size_mb":80},
             {"id":"chromium","title":"Chromium","group":"web","packages":["chromium"],"size_mb":100},
             {"id":"git","title":"git","group":"develop","packages":["git"],"size_mb":20},
             {"id":"vlc","title":"VLC","group":"media","packages":["vlc"],"size_mb":60},
             {"no_id":true}],
     "ssh":{"port_min":1,"port_max":65535,"default_port":22}}
    """

    static let versionsJSON = """
    {"additions":"1.11.0+5","suite":"trixie","arch":"arm64","packages":{"tux-guest":"1.11.0","tux-va":"1.0.1","tux-ffmpeg":"9.0.2-tux10","tux-codec-dkms":"1.0.0"},
     "optional":["tux-codec-dkms"],"built":"15/11/2026"}
    """

    // A public key line as ssh-keygen writes it: base64 of length-prefixed fields.
    static func field(_ bytes: [UInt8]) -> [UInt8] {
        let n = UInt32(bytes.count)
        return [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] + bytes
    }

    static func keyLine(_ type: String, _ fields: [[UInt8]], comment: String? = "me@phone") -> String {
        let blob = ([Array(type.utf8)] + fields).flatMap(field)
        return type + " " + Data(blob).base64EncodedString() + (comment.map { " " + $0 } ?? "")
    }

    static func validKeys() -> [String: String] {
        let bytes = { (n: Int) in (0..<n).map { UInt8(($0 &* 7 &+ 1) & 255) } }
        var out: [String: String] = [
            "ssh-ed25519": keyLine("ssh-ed25519", [bytes(32)]),
            "ssh-rsa": keyLine("ssh-rsa", [[1, 0, 1], bytes(257)]),
            "sk-ssh-ed25519@openssh.com": keyLine("sk-ssh-ed25519@openssh.com", [bytes(32), Array("ssh:".utf8)]),
        ]
        for (type, curve, point) in [("ecdsa-sha2-nistp256", "nistp256", 65), ("ecdsa-sha2-nistp384", "nistp384", 97), ("ecdsa-sha2-nistp521", "nistp521", 133)] {
            out[type] = keyLine(type, [Array(curve.utf8), bytes(point)])
        }
        return out
    }

    static let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl me@phone"

    static func report(_ edit: (inout AdditionsReport) -> Void = { _ in }) -> AdditionsReport {
        var r = try! JSONDecoder().decode(AdditionsReport.self, from: Data(reportJSON.utf8))
        edit(&r)
        return r
    }

    static let catalogue = AdditionsCatalogue.decode(Data(actionsJSON.utf8))!
    static let versionSet = AdditionsVersions.decode(Data(versionsJSON.utf8))!

    // MARK: Versions

    static func versions() {
        let c = AdditionsPolicy.compareVersions
        check("1.10.2 before 1.11.0", c("1.10.2", "1.11.0") == -1 && c("1.11.0", "1.10.2") == 1)
        check("equal", c("1.11.0", "1.11.0") == 0)
        check("9.0.2-tux2 before 9.0.2-tux10", c("9.0.2-tux2", "9.0.2-tux10") == -1 && c("9.0.2-tux10", "9.0.2-tux2") == 1)
        check("a revision after none", c("9.0.2", "9.0.2-tux1") == -1)
        check("numbers, not text", c("1.9", "1.10") == -1 && c("1.010", "1.10") == 0)
        check("tilde before the end", c("1.0~rc1", "1.0") == -1 && c("1.0~~", "1.0~") == -1)
        check("plus after the end", c("1.11.0", "1.11.0+5") == -1)
        check("a letter after the end", c("1.0", "1.0a") == -1 && c("1.0a", "1.0b") == -1)
        check("epoch wins", c("1:0.1", "9.9") == 1 && c("0:1.0", "1.0") == 0)
        check("the last dash starts the revision", c("1.0-2-3", "1.0-2-10") == -1)

        let installed = ["tux-guest": "1.10.2", "tux-va": "1.0.1", "tux-ffmpeg": "9.0.2-tux2"]
        let bundled = versionSet.packages
        check("optional read from the media", versionSet.optional == ["tux-codec-dkms"])
        check("no optional field: tux-codec-dkms is optional",
              AdditionsVersions.decode(Data(#"{"packages":{"tux-guest":"1.11.0"}}"#.utf8))?.optional == ["tux-codec-dkms"])
        check("an empty optional field: nothing is optional",
              AdditionsVersions.decode(Data(#"{"packages":{},"optional":[]}"#.utf8))?.optional == [])
        check("optional of the wrong type is skipped",
              AdditionsVersions.decode(Data(#"{"packages":{},"optional":["a",1,null]}"#.utf8))?.optional == ["a"])
        check("older ones listed", AdditionsPolicy.outdated(installed: installed, bundled: bundled) == ["tux-ffmpeg", "tux-guest"])
        check("same version is not older", AdditionsPolicy.outdated(installed: bundled, bundled: bundled).isEmpty)
        check("newer in the guest is not older", AdditionsPolicy.outdated(installed: ["tux-guest": "1.12.0"], bundled: bundled).isEmpty)
        check("a missing package is not older", AdditionsPolicy.outdated(installed: ["tux-va": "1.0.1"], bundled: bundled).isEmpty)
        check("a missing package is listed as missing, an optional one is not",
              AdditionsPolicy.missing(installed: ["tux-va": "1.0.1"], bundled: bundled) == ["tux-ffmpeg", "tux-guest"]
              && AdditionsPolicy.missing(installed: ["tux-va": "1.0.1"], bundled: bundled, optional: []) == ["tux-codec-dkms", "tux-ffmpeg", "tux-guest"])
        check("changes: older and missing, not current",
              AdditionsPolicy.changes(installed: installed, bundled: bundled) == [
                  .init(name: "tux-ffmpeg", from: "9.0.2-tux2", to: "9.0.2-tux10"), .init(name: "tux-guest", from: "1.10.2", to: "1.11.0")]
              && AdditionsPolicy.changes(installed: ["tux-guest": "1.11.0"], bundled: bundled) == [
                  .init(name: "tux-ffmpeg", from: nil, to: "9.0.2-tux10"), .init(name: "tux-va", from: nil, to: "1.0.1")])
        check("changes: nothing when current", AdditionsPolicy.changes(installed: bundled.filter { $0.key != "tux-codec-dkms" }, bundled: bundled).isEmpty)
        check("update banner", AdditionsPolicy.updateAvailable(report().caps, versions: versionSet))
        var legacy = report().caps
        legacy.legacy = true
        check("no banner for a legacy guest", !AdditionsPolicy.updateAvailable(legacy, versions: versionSet))
        check("no banner without a report or versions", !AdditionsPolicy.updateAvailable(nil, versions: versionSet)
              && !AdditionsPolicy.updateAvailable(report().caps, versions: nil))
        var current = report().caps
        current.installed = bundled
        check("no banner when current", !AdditionsPolicy.updateAvailable(current, versions: versionSet))
        check("guest version", AdditionsPolicy.guestVersion(report().caps) == "1.10.2" && AdditionsPolicy.guestVersion(nil) == nil)
        check("protocol", AdditionsPolicy.protocolSupported(report()) && !AdditionsPolicy.protocolSupported(report { $0.protocolVersion = 2 })
              && AdditionsPolicy.protocolSupported(report { $0.protocolVersion = nil }))
    }

    // MARK: Validators

    static func validators() {
        let user = AdditionsPolicy.validUserName
        for ok in ["tux", "_x", "a", "a-b_c9", String(repeating: "a", count: 32)] { check("user ok \(ok)", user(ok)) }
        for bad in ["", "Tux", "1abc", "-a", "a b", "a.b", "tux\n", "a:b", "é", String(repeating: "a", count: 33), "a/b", "root\u{0}"] {
            check("user bad \(bad.debugDescription)", !user(bad))
        }

        let host = AdditionsPolicy.validHostName
        for ok in ["a", "tuxbox", "a-b", "9lives", "a1", String(repeating: "a", count: 63)] { check("host ok \(ok)", host(ok)) }
        for bad in ["", "-a", "a-", "A", "a_b", "a.b", "a b", "tux\n", String(repeating: "a", count: 64), "é"] {
            check("host bad \(bad.debugDescription)", !host(bad))
        }

        check("port ok", AdditionsPolicy.port("22") == 22 && AdditionsPolicy.port("1") == 1 && AdditionsPolicy.port("65535") == 65535
              && AdditionsPolicy.port(" 2222 ") == 2222)
        for bad in ["", "0", "65536", "-1", "+22", "22a", "2 2", "100000", "٢٢", "22\n22"] { check("port bad \(bad.debugDescription)", AdditionsPolicy.port(bad) == nil) }

        let valid = AdditionsPolicy.validAuthorizedKey
        check("key ed25519 with a comment", valid(key))
        check("key without a comment", valid("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"))
        check("key with a final newline", valid(key + "\n"))
        let keys = validKeys()
        for type in AdditionsPolicy.keyTypes { check("key type \(type)", keys[type].map(valid) == true) }
        check("every key type has a test key", Set(keys.keys) == Set(AdditionsPolicy.keyTypes))
        check("a key with no comment, or a comment with spaces", valid(keyLine("ssh-rsa", [[1, 0, 1], [UInt8](repeating: 9, count: 257)], comment: nil))
              && valid(keys["ssh-ed25519"]! + " and more words"))
        check("the old fixture is a good key", valid(key) && valid("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"))
        check("curly apostrophe in the comment", !valid(key + " Sam\u{2019}s iPhone") && valid(key + " Sam's iPhone"))
        check("any non-ASCII or DEL in the comment", !valid(key + " caf\u{e9}") && !valid(key + " me\u{7f}") && !valid(key + " me\tphone"))
        let bare = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        check("a truncated key", valid(bare) && !valid(String(bare.dropLast(4))) && !valid(String(bare.dropLast(8))) && !valid("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMq"))
        check("a truncated rsa key", !valid(String(keys["ssh-rsa"]!.split(separator: " ")[0] + " " + keys["ssh-rsa"]!.split(separator: " ")[1].dropLast(8))))
        let blob = { (line: String) in String(line.split(separator: " ")[1]) }
        check("the declared type must be the blob's type", !valid("ssh-rsa " + blob(keys["ssh-ed25519"]!)) && !valid("ssh-ed25519 " + blob(keys["ssh-rsa"]!))
              && !valid("ecdsa-sha2-nistp384 " + blob(keys["ecdsa-sha2-nistp256"]!)))
        check("an ed25519 key is 32 bytes", !valid(keyLine("ssh-ed25519", [Array(repeating: 1, count: 31)])) && !valid(keyLine("ssh-ed25519", [Array(repeating: 1, count: 33)])))
        check("wrong number of fields", !valid(keyLine("ssh-ed25519", [Array(repeating: 1, count: 32), [1]])) && !valid(keyLine("ssh-rsa", [[1, 0, 1]]))
              && !valid(keyLine("ecdsa-sha2-nistp256", [Array("nistp256".utf8)])))
        check("bytes after the last field", !valid("ssh-ed25519 " + Data(([Array("ssh-ed25519".utf8)] + [Array(repeating: 1, count: 32)]).flatMap(field) + [0]).base64EncodedString()))
        check("a field that runs past the end", !valid("ssh-ed25519 " + Data(field(Array("ssh-ed25519".utf8)) + [0, 0, 0, 40] + Array(repeating: 1, count: 32)).base64EncodedString()))
        check("key bad type", !valid("ssh-dss AAAAB3NzaC1kc3MAAAA=") && !valid("AAAAC3NzaC1lZDI1NTE5AAAAIOMq ssh-ed25519"))
        check("key empty or no body", !valid("") && !valid("ssh-ed25519") && !valid("ssh-ed25519 "))
        check("key body not base64", !valid("ssh-ed25519 AAAA!AAA") && !valid("ssh-ed25519 AAA") && !valid("ssh-ed25519 AA=A"))
        check("key with a line break inside", !valid("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMq\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMq"))
        check("key with a control character", !valid("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMq me\u{7}"))
        check("key of 4 KB at most", valid(keyLine("ssh-rsa", [[1, 0, 1], [UInt8](repeating: 5, count: 2900)], comment: nil))
              && !valid(keyLine("ssh-rsa", [[1, 0, 1], [UInt8](repeating: 5, count: 3100)], comment: nil)))

        check("no password is no problem", AdditionsPolicy.passwordProblem("", confirm: "") == nil)
        check("password ok", AdditionsPolicy.passwordProblem("s3cret é", confirm: "s3cret é") == nil)
        check("password mismatch", AdditionsPolicy.passwordProblem("a", confirm: "b") == AdditionsText.passwordMismatch)
        check("password line break", AdditionsPolicy.passwordProblem("a\nb", confirm: "a\nb") == AdditionsText.passwordControl)
        check("password too long", AdditionsPolicy.passwordProblem(String(repeating: "a", count: 129), confirm: String(repeating: "a", count: 129)) == AdditionsText.passwordLong)
    }

    // MARK: The job

    static func json(_ text: String) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: Data(text.utf8))) as! [String: Any]
    }

    static func same(_ a: Any, _ b: Any) -> Bool {
        (a as? NSObject)?.isEqual(b as? NSObject) == true
    }

    static func job() throws {
        let secret = "hunter2-Passw0rd"
        let steps: [AdditionsJob.Step] = [
            .additionsInstall,
            .userSetup(name: "tux", password: secret, sudo: true, autologin: true, lockRoot: true),
            .hostnameSet(name: "tuxbox"),
            .desktopInstall(id: "labwc"),
            .appsInstall(ids: ["firefox", "git"]),
            .sshConfigure(enabled: true, port: 22, passwordAuth: false, rootLogin: false, authorizedKey: key),
            .systemUpdate,
        ]
        let job = AdditionsJob(id: "j-8f3a", steps: steps)
        let text = job.json()!
        check("no reboot_after unless it is set", !text.contains("reboot_after"))
        var restart = job
        restart.rebootAfter = true
        check("reboot_after true when set", json(restart.json()!)["reboot_after"] as? Bool == true)
        let expected: [String: Any] = ["id": "j-8f3a", "steps": [
            ["action": "additions.install"],
            ["action": "user.setup", "name": "tux", "password": secret, "sudo": true, "autologin": true, "lock_root": true],
            ["action": "hostname.set", "name": "tuxbox"],
            ["action": "desktop.install", "id": "labwc"],
            ["action": "apps.install", "ids": ["firefox", "git"]],
            ["action": "ssh.configure", "enabled": true, "port": 22, "password_auth": false, "root_login": false, "authorized_key": key],
            ["action": "system.update"],
        ] as [Any]]
        check("the job has the exact shape of design 5.5", same(json(text), expected))
        check("the password is in the JSON once", text.components(separatedBy: secret).count == 2)
        check("the password is only in user.setup", {
            let s = json(text)["steps"] as! [[String: Any]]
            return s.filter { $0["password"] != nil }.map { $0["action"] as! String } == ["user.setup"]
        }())
        var dumped = ""
        dump(job, to: &dumped)
        check("no password text outside the JSON", ![ "\(job)", String(reflecting: job), "\(steps)", String(reflecting: steps), dumped ].contains { $0.contains(secret) })
        check("the description names no secret", "\(job)" == "job j-8f3a, 7 steps" && "\(steps[1])" == "user.setup")

        let bytes = job.jsonBytes()!
        check("jsonBytes is the JSON and a zero byte", bytes.last == 0 && String(decoding: bytes.dropLast(), as: UTF8.self) == text && !bytes.dropLast().contains(0))

        let known: Set<String> = ["action", "name", "password", "sudo", "autologin", "lock_root", "id", "ids", "enabled", "port",
                                  "password_auth", "root_login", "authorized_key"]
        for s in json(text)["steps"] as! [[String: Any]] { check("no unknown keys in \(s["action"]!)", Set(s.keys).isSubset(of: known)) }
        check("top-level keys", Set(json(text).keys) == ["id", "steps"])

        let noPassword = AdditionsJob(id: "j-1", steps: [.userSetup(name: "tux", password: nil, sudo: false, autologin: false, lockRoot: false)])
        let step = (json(noPassword.json()!)["steps"] as! [[String: Any]])[0]
        check("no password: no key", step["password"] == nil && same(step["sudo"]!, false) && same(step["lock_root"]!, false))
        let emptyPassword = AdditionsJob(id: "j-1", steps: [.userSetup(name: "tux", password: "", sudo: true, autologin: true, lockRoot: true)])
        check("an empty password is left out", !emptyPassword.json()!.contains("password"))

        let noKey = AdditionsJob(id: "j-2", steps: [.sshConfigure(enabled: false, port: 22, passwordAuth: true, rootLogin: false, authorizedKey: nil)])
        check("no key: no authorized_key", !noKey.json()!.contains("authorized_key"))
        check("an empty job has no JSON", AdditionsJob(id: "j-3", steps: []).json() == nil)
        let big = AdditionsJob(id: "j-4", steps: [.appsInstall(ids: (0..<2000).map { "app-\($0)-xxxxxxxx" })])
        check("a job over 16 KB has no JSON", big.json() == nil)
        let id = AdditionsJob.newID()
        check("job ids", id.hasPrefix("j-") && id.count == 10 && id != AdditionsJob.newID())
        check("the account's name and index", job.accountName == "tux" && job.accountStepIndex == 1
              && AdditionsJob(id: "x", steps: [.systemUpdate]).accountName == nil)
        check("step titles", steps[3].title(catalogue) == "Set up Tuxedo desktop (labwc)" && steps[4].title(catalogue) == "Install Firefox and git"
              && AdditionsJob.Step.appsInstall(ids: ["a", "b", "c"]).title(nil) == "Install 3 applications")
    }

    // MARK: Events

    static func feed(_ events: [(UInt64, String)], inserted: Bool = true, n: Int = 3, seq: UInt64 = 42, gap: Bool = false) -> String {
        let items = events.map { "{\"k\":\($0.0),\"e\":\($0.1)}" }.joined(separator: ",")
        return "{\"inserted\":\(inserted),\"n\":\(n),\"seq\":\(seq),\"gap\":\(gap),\"events\":[\(items)]}"
    }

    static func events() throws {
        let step = { (job: String, i: Int, status: String, msg: String) in
            "{\"t\":\"step\",\"job\":\"\(job)\",\"i\":\(i),\"status\":\"\(status)\",\"msg\":\"\(msg)\"}"
        }
        let log = { (job: String, text: String) in "{\"t\":\"log\",\"job\":\"\(job)\",\"text\":\"\(text)\"}" }
        let done = { (job: String, ok: Bool) in
            "{\"t\":\"done\",\"job\":\"\(job)\",\"ok\":\(ok),\"reboot\":true,\"info\":{\"ips\":[\"10.0.2.15\"],\"ssh_fingerprints\":[\"256 SHA256:abc root@x (ED25519)\"],\"user\":\"bob\"}}"
        }

        let text = feed([(40, reportJSON), (41, step("j1", 0, "running", "Installing")), (42, log("j1", "Reading\\n"))])
        let f = AdditionsFeed.decode(text)!
        check("feed header", f.inserted && f.n == 3 && f.seq == 42 && !f.gap && f.events.map(\.k) == [40, 41, 42] && f.lastK == 42)
        var s = AdditionsState()
        s.apply(f)
        check("report kept", s.report?.agent == "1.11.0+5" && s.report?.n == 3 && s.caps?.account?.configured == false && s.caps?.network == true)
        check("step and log", s.job?.id == "j1" && s.job?.steps[0] == .init(status: .running, message: "Installing") && s.job?.log == "Reading\n")
        check("running", s.running && s.lastK == 42 && s.inserted && s.n == 3)

        s.apply(f)
        check("the same events twice change nothing", s.job?.log == "Reading\n" && s.lastK == 42)

        s.apply(AdditionsFeed.decode(feed([(43, step("j1", 0, "ok", "Done")), (44, step("j1", 1, "failed", "No network")),
                                           (45, step("j1", 2, "skipped", "")), (46, done("j1", false))]))!)
        check("steps by index", s.job?.steps[0]?.status == .ok && s.job?.steps[1]?.status == .failed && s.job?.steps[2]?.status == .skipped
              && s.job?.steps[1]?.message == "No network")
        check("done", !s.running && s.job?.done == .init(ok: false, reboot: true, info: .init(ips: ["10.0.2.15"],
              sshFingerprints: ["256 SHA256:abc root@x (ED25519)"], user: "bob")))
        check("current step", s.job?.currentStep(of: 4) == 3 && AdditionsJobProgress(id: "x").currentStep(of: 2) == 0)

        s.apply(AdditionsFeed.decode(feed([(47, step("j2", 0, "running", "Again"))]))!)
        check("a new job id starts new progress", s.job?.id == "j2" && s.job?.steps.count == 1 && s.job?.log == "" && s.job?.done == nil)

        var local = AdditionsState()
        local.beginJob(id: "mine")
        local.apply(AdditionsFeed.decode(feed([(1, step("old", 0, "running", "Late")), (2, log("old", "late")), (3, step("mine", 0, "ok", "Fine"))]))!)
        check("the app's job ignores a late event of another job", local.job?.id == "mine" && local.job?.steps[0]?.status == .ok && local.job?.log == "")
        local.apply(AdditionsFeed.decode(feed([(4, done("mine", true))]))!)
        local.apply(AdditionsFeed.decode(feed([(5, step("other", 0, "running", "x"))]))!)
        check("after done a new job is followed", local.job?.id == "other")
        local.clearJob()
        check("clear", local.job == nil)

        var gap = AdditionsState()
        gap.apply(AdditionsFeed.decode(feed([(100, step("j", 0, "ok", ""))], gap: true))!)
        check("a gap is noted and the events still apply", gap.gap && gap.job?.steps[0]?.status == .ok)
        gap.apply(AdditionsFeed.decode(feed([], gap: false))!)
        check("the gap ends", !gap.gap)

        var bad = AdditionsState()
        bad.apply(.badMedia(n: 3, why: "bad signature"))
        check("bad media", bad.badMedia == "bad signature")
        bad.apply(.badMedia(n: 3, why: ""))
        check("bad media with no reason", bad.badMedia == AdditionsText.badMedia)
        bad.apply(.report(report()))
        check("a report clears bad media", bad.badMedia == nil)

        let unknown = AdditionsFeed.decode(feed([(7, "{\"t\":\"future\",\"x\":1}"), (9, "{\"t\":\"step\",\"job\":\"j\"}")]))!
        check("events of an unknown type still advance since", unknown.events.isEmpty && unknown.lastK == 9)
        var unknownState = AdditionsState()
        unknownState.apply(unknown)
        check("and the state's lastK", unknownState.lastK == 9)
        let mixed = AdditionsFeed.decode(feed([(7, "{\"t\":\"future\"}"), (8, step("j", 0, "ok", "")), (9, "{\"t\":\"later\"}")]))!
        check("a unknown event after the last known one counts", mixed.events.map(\.k) == [8] && mixed.lastK == 9)

        let odd = AdditionsFeed.decode(feed([(1, "{\"t\":\"future\",\"x\":1}"), (2, "{\"t\":\"step\",\"job\":\"j\"}"), (3, "{\"nope\":1}"),
                                             (4, step("j", 0, "weird", "")), (5, step("j", 1, "ok", ""))]))!
        check("unknown and malformed events are left out", odd.events.map(\.k) == [5])
        check("not JSON", AdditionsFeed.decode("nope") == nil && AdditionsFeed.decode("[1]") == nil)
        check("an empty feed", AdditionsFeed.decode("{\"inserted\":false,\"n\":0,\"seq\":0,\"gap\":false,\"events\":[]}")?.events.isEmpty == true)

        var long = AdditionsState()
        let chunk = String(repeating: "x", count: 4000)
        for k in 1...30 { long.apply(.log(job: "j", text: chunk + "\(k)")); long.lastK = UInt64(k) }
        check("the log keeps the newest 64 KB", (long.job?.log.count ?? 0) <= AdditionsState.logLimit && long.job?.log.hasSuffix("30") == true)

        var ready = AdditionsState()
        ready.apply(AdditionsFeed.decode(feed([(1, reportJSON)], n: 3))!)
        check("the agent is ready when its report is for this insert", ready.agentReady)
        ready.apply(AdditionsFeed.decode(feed([], n: 4))!)
        check("a new insert waits for a new report", !ready.agentReady)
        var boot = AdditionsState()
        boot.apply(AdditionsFeed.decode(feed([(1, "{\"t\":\"report\",\"caps\":{}}")], inserted: false, n: 0))!)
        check("a boot report has no agent", !boot.agentReady && boot.report != nil)
    }

    // MARK: How a job ends

    static func jobFeed(_ events: [(UInt64, String)]) -> AdditionsFeed { AdditionsFeed.decode(feed(events))! }
    static let ackText = { (job: String) in "{\"t\":\"ack\",\"job\":\"\(job)\"}" }
    static let stepText = { (job: String, i: Int, status: String) in "{\"t\":\"step\",\"job\":\"\(job)\",\"i\":\(i),\"status\":\"\(status)\",\"msg\":\"\"}" }
    static let doneText = { (job: String) in "{\"t\":\"done\",\"job\":\"\(job)\",\"ok\":true,\"reboot\":false,\"info\":{}}" }

    static func jobEnds() {
        // ack: the agent has the job.
        var s = AdditionsState()
        s.beginJob(id: "j1")
        check("a new job runs, not taken", s.running && s.job?.taken == false && !(s.job?.over ?? true))
        s.apply(jobFeed([(1, ackText("j1"))]))
        check("ack: taken, still running", s.job?.taken == true && s.running && s.job?.steps.isEmpty == true)
        check("ack decodes", AdditionsFeed.decode(feed([(1, ackText("j1"))]))?.events.first?.event == .ack(job: "j1"))
        check("ack with no job is not an event", AdditionsFeed.decode(feed([(1, "{\"t\":\"ack\"}")]))?.events.isEmpty == true)
        s.apply(jobFeed([(2, stepText("j1", 0, "running"))]))
        check("a step also means taken", s.job?.taken == true)
        s.apply(jobFeed([(3, doneText("j1"))]))
        check("done ends it", !s.running && s.job?.over == true && s.job?.done?.ok == true && s.job?.stopped == nil)

        // A step with no ack (an agent that sends no ack) is taken too.
        var noAck = AdditionsState()
        noAck.beginJob(id: "j2")
        noAck.apply(jobFeed([(1, stepText("j2", 0, "running"))]))
        check("a step with no ack: taken", noAck.job?.taken == true && !noAck.abandon(.noAnswer) && noAck.running)

        // Cancel before the ack: the engine wipes the job and nobody posts done.
        var c = AdditionsState()
        c.beginJob(id: "j3")
        check("cancel before the ack ends the job at once", c.abandon(.cancelled) && !c.running && c.job?.stopped == .cancelled && c.job?.done == nil)
        check("a second abandon changes nothing", !c.abandon(.noAnswer) && c.job?.stopped == .cancelled)
        var cancelledAfterAck = AdditionsState()
        cancelledAfterAck.beginJob(id: "j4")
        cancelledAfterAck.apply(jobFeed([(1, ackText("j4"))]))
        check("cancel after the ack waits for the agent's done", !cancelledAfterAck.abandon(.cancelled) && cancelledAfterAck.running)

        // Timeout: no ack and no step.
        var t = AdditionsState()
        t.beginJob(id: "j5")
        check("no answer ends the job", t.abandon(.noAnswer) && !t.running && t.job?.stopped == .noAnswer)
        check("the app's job: a new one starts and the dead one is gone", { var n = t; n.beginJob(id: "j6"); return n.running && n.job?.id == "j6" && n.job?.stopped == nil }())
        t.apply(jobFeed([(1, stepText("j9", 0, "running"))]))
        check("after the end, events of another job are followed", t.job?.id == "j9")

        // Bad media.
        var b = AdditionsState()
        b.beginJob(id: "j7")
        b.apply(AdditionsFeed.decode(feed([(1, "{\"t\":\"bad-media\",\"n\":2,\"why\":\"bad signature\"}")]))!)
        check("bad media ends a job that is not taken", !b.running && b.job?.stopped == .badMedia("bad signature") && b.badMedia == "bad signature")
        var le = AdditionsState()
        le.beginJob(id: "j7b")
        le.apply(AdditionsFeed.decode(feed([(1, "{\"t\":\"launch-error\",\"n\":2,\"why\":\"disk full\"}")]))!)
        check("launch error ends a job that is not taken", !le.running && (le.badMedia ?? "").contains("disk full"))
        var bt = AdditionsState()
        bt.beginJob(id: "j8")
        bt.apply(jobFeed([(1, ackText("j8"))]))
        bt.apply(.badMedia(n: 2, why: "x"))
        check("bad media does not end a job the agent has taken", bt.running && bt.badMedia == "x")
        var bn = AdditionsState()
        bn.apply(.badMedia(n: 1, why: "x"))
        check("bad media with no job of the app's", bn.job == nil && bn.badMedia == "x")

        // The late events of a dead job.
        var late = AdditionsState()
        late.beginJob(id: "old")
        late.abandon(.cancelled)
        late.apply(jobFeed([(1, ackText("old")), (2, doneText("old"))]))
        check("a late done for the cancelled job still applies", late.job?.done?.ok == true && late.job?.stopped == .cancelled && !late.running)
        late.beginJob(id: "new")
        late.apply(jobFeed([(3, stepText("old", 0, "running"))]))
        check("late events of the old job do not touch the new one", late.job?.id == "new" && late.job?.steps.isEmpty == true && late.running)

        // Policy.
        check("the start timeout is 90 s", AdditionsPolicy.jobStartTimeout == 90)
        check("Leave as it is dismisses the prompt only when the account is not set up",
              AdditionsPolicy.leavesAccountUnset(job: nil, caps: report().caps)
              && !AdditionsPolicy.leavesAccountUnset(job: "tux", caps: report().caps)
              && !AdditionsPolicy.leavesAccountUnset(job: nil, caps: report { $0.caps.account?.configured = true }.caps)
              && !AdditionsPolicy.leavesAccountUnset(job: nil, caps: report { $0.caps.account = nil }.caps)
              && !AdditionsPolicy.leavesAccountUnset(job: nil, caps: nil))
        check("texts", AdditionsText.noAnswer == "The guest did not answer." && AdditionsText.notInThisApp == "This build has no Additions media.")
    }

    // MARK: The bundled files

    static func catalogueAndVersions() throws {
        check("catalogue desktops", catalogue.desktops.map(\.id) == ["labwc", "plasma", "xfce"] && catalogue.desktop("plasma")?.sizeMB == 1500)
        check("catalogue apps skip a bad entry", catalogue.apps.map(\.id) == ["firefox", "chromium", "git", "vlc"])
        check("catalogue groups in order", catalogue.appGroups.map(\.group) == ["web", "media", "develop"]
              && catalogue.appGroups[0].apps.map(\.id) == ["firefox", "chromium"])
        check("catalogue ssh", catalogue.ssh == .init(portMin: 1, portMax: 65535, defaultPort: 22) && catalogue.protocolVersion == 1)
        check("catalogue not JSON", AdditionsCatalogue.decode(Data("x".utf8)) == nil)
        check("sizes", AdditionsCatalogue.sizeText(80) == "80 MB" && AdditionsCatalogue.sizeText(1500) == "1.5 GB" && AdditionsCatalogue.sizeText(999) == "999 MB")
        check("group titles", AdditionsCatalogue.groupTitle("web") == "Web" && AdditionsCatalogue.groupTitle("games") == "Games")
        check("versions", versionSet.additions == "1.11.0+5" && versionSet.packages["tux-ffmpeg"] == "9.0.2-tux10" && versionSet.built == "15/11/2026")
        check("versions not JSON", AdditionsVersions.decode(Data("[]".utf8)) == nil)
    }

    // MARK: The wizard

    static func model(_ edit: (inout AdditionsCaps) -> Void = { _ in }, start: AdditionsStep? = nil, intro: Bool = false) -> AdditionsWizardModel {
        var caps = report().caps
        edit(&caps)
        return AdditionsWizardModel(caps: caps, versions: versionSet, catalogue: catalogue, start: start, intro: intro)
    }

    static func wizard() {
        // Connect waits for the first report.
        var m = AdditionsWizardModel(caps: nil, versions: versionSet, catalogue: catalogue)
        check("no report: connect only", m.step == .connect && m.flow.first == .connect && m.overviewRows.isEmpty)
        m.update(report: report())
        check("a report moves on from connect", m.step == .overview && !m.flow.contains(.connect))

        // Defaults from the caps: the account tux exists with no password and is not set up.
        m = model()
        check("defaults: keep the account and set a password", m.accountMode == .existing && m.existingName == "tux" && m.accountName == "tux"
              && m.sudo && m.autologin && m.lockRoot && !m.accountWillHavePassword)
        check("account modes", m.accountModes == [.existing, .new, .unchanged])
        check("defaults: additions on, nothing else", m.installAdditions && m.desktop == nil && m.apps.isEmpty && !m.systemUpdate && !m.sshEnabled && m.sshPortText == "22")
        check("flow", m.flow == [.overview, .account, .additions, .desktop, .applications, .ssh, .review])
        m = model { $0.account = AdditionsAccount(name: "tux", uid: 1000, exists: false, configured: false) }
        check("no account: make one named tux", m.accountMode == .new && m.userName == "tux" && m.existingName == nil && m.accountModes == [.new, .unchanged])
        m = model { $0.account = AdditionsAccount(name: "bob", uid: 1000, exists: true, passwordSet: true, configured: true, sudo: false, autologin: "none") }
        check("configured: leave it", m.accountMode == .unchanged && !m.sudo && !m.autologin && m.accountWillHavePassword && m.jobSteps().contains { $0 == .additionsInstall })
        m = model { $0.account = nil }
        check("no account object: leave it", m.accountMode == .unchanged)

        // Skip rules.
        m = model { $0.installed = versionSet.packages }
        check("additions up to date: step skipped", !m.flow.contains(.additions) && m.additionsAction == .none && !m.installAdditions)
        var noDkms = versionSet.packages
        noDkms["tux-codec-dkms"] = nil
        m = model { $0.installed = noDkms }
        check("an up-to-date guest with no tux-codec-dkms: no step, no action",
              m.additionsAction == .none && !m.flow.contains(.additions) && !m.installAdditions && m.additionsChanges.isEmpty
              && !m.jobSteps().contains(.additionsInstall))
        m = model { $0.installed = noDkms.merging(["tux-ffmpeg": "9.0.2-tux2"]) { $1 } }
        check("one older package: update, and only that row", m.additionsAction == .update
              && m.additionsChanges == [.init(name: "tux-ffmpeg", from: "9.0.2-tux2", to: "9.0.2-tux10")])
        m = model { $0.installed = noDkms; $0.installed["tux-va"] = nil }
        check("a really missing package: install", m.additionsAction == .install && m.additionsChanges == [.init(name: "tux-va", from: nil, to: "1.0.1")])
        let noField = AdditionsVersions.decode(Data(#"{"packages":{"tux-guest":"1.11.0","tux-codec-dkms":"1.0.0"}}"#.utf8))!
        let old = AdditionsWizardModel(caps: { var c = report().caps; c.installed = ["tux-guest": "1.11.0"]; return c }(), versions: noField, catalogue: catalogue)
        check("a media with no optional field: dkms is still skipped", old.additionsAction == .none)
        let strict = AdditionsVersions.decode(Data(#"{"packages":{"tux-guest":"1.11.0","tux-codec-dkms":"1.0.0"},"optional":[]}"#.utf8))!
        let required = AdditionsWizardModel(caps: { var c = report().caps; c.installed = ["tux-guest": "1.11.0"]; return c }(), versions: strict, catalogue: catalogue)
        check("a media that makes it required: install", required.additionsAction == .install)
        m = model { $0.installed = ["tux-guest": "1.11.0"] }
        check("missing packages: install", m.additionsAction == .install && m.flow.contains(.additions))
        check("older packages: update", model().additionsAction == .update)
        m = model { $0.desktop = "xfce"; $0.desktops = ["xfce"] }
        check("a desktop is there: the step stays, to switch", m.flow.contains(.desktop))
        check("the desktop in use is marked and cannot be picked", m.desktopChoices.first { $0.id == "xfce" }?.disabledReason == AdditionsText.current
              && m.desktopChoices.first { $0.id == "xfce" }?.marks == [AdditionsText.current])
        check("keep names the desktop", m.desktopChoices.first?.title == "Keep Xfce")
        m = model { $0.desktop = "labwc"; $0.desktops = ["labwc", "plasma"]; $0.network = false }
        let plasma = m.desktopChoices.first { $0.id == "plasma" }
        check("an installed desktop is a pick with no download, also with no network", plasma?.disabledReason == nil && plasma?.sizeMB == 0
              && plasma?.marks == [AdditionsText.installed])
        m.chooseDesktop("plasma")
        check("it is chosen with no network", m.desktop == "plasma" && m.jobSteps().map(\.action).contains("desktop.install"))
        m.update(report: report { $0.caps.desktop = "labwc"; $0.caps.desktops = ["labwc", "plasma"]; $0.caps.network = false })
        check("a report with no network keeps an installed pick", m.desktop == "plasma")
        check("the desktop in the job asks for a restart", m.needsRestart && m.restartsAfter && m.job()?.rebootAfter == true)
        m.restartAfter = false
        check("the switch turns the restart off", m.needsRestart && !m.restartsAfter && m.job()?.rebootAfter == false)
        check("no desktop in the job: no restart", { let n = model(); return !n.needsRestart && !n.restartsAfter && n.job()?.rebootAfter == false }())
        check("an installed desktop in the review", m.reviewLines.contains { $0.title == "Use KDE Plasma" })
        m = model { $0.desktop = "labwc"; $0.desktops = ["labwc"] }
        check("a report with no desktops list takes the desktop", { var c = AdditionsCaps(); c.desktop = "labwc"
            let d = try? JSONDecoder().decode(AdditionsCaps.self, from: Data(#"{"desktop":"labwc"}"#.utf8)); _ = c; return d?.desktops == ["labwc"] }())
        check("no versions: no additions step", AdditionsWizardModel(caps: report().caps, versions: nil, catalogue: catalogue).flow.contains(.additions) == false)
        check("no catalogue: no desktop or apps step", { let w = AdditionsWizardModel(caps: report().caps, versions: versionSet, catalogue: nil)
            return !w.flow.contains(.desktop) && !w.flow.contains(.applications) && w.flow.contains(.ssh) }())

        // Next and back.
        m = model()
        check("next and back", m.next == .account && m.back == nil)
        m.goNext()
        check("goNext", m.step == .account && m.back == .overview && m.next == .additions)
        m.goBack()
        check("goBack", m.step == .overview && m.back == nil)
        m.step = .review
        check("review has no next", m.next == nil && !m.canGoNext)

        // The account prompt opens at Account with the question.
        m = model(start: .account, intro: true)
        check("intro at account", m.step == .account && m.showsIntro && m.back == nil)
        m.acceptIntro()
        check("intro accepted", !m.showsIntro && m.back == .overview)
        check("no intro without a report", !AdditionsWizardModel(caps: nil, start: .account, intro: true).showsIntro)

        // No network turns the options off, with a reason.
        m = model { $0.network = false }
        check("no network: desktop tiles off", m.desktopChoices.filter { $0.id != AdditionsWizardModel.keepConsoleID }.allSatisfy { $0.disabledReason == AdditionsText.noNetwork }
              && m.desktopChoices.first?.disabledReason == nil)
        check("no network: app tiles off", m.appChoices(group: "web").allSatisfy { $0.disabledReason == AdditionsText.noNetwork })
        m.chooseDesktop("labwc")
        m.toggleApp("firefox")
        check("no network: nothing can be picked", m.desktop == nil && m.apps.isEmpty)
        m = model()
        m.chooseDesktop("labwc")
        m.toggleApp("firefox")
        m.toggleApp("vlc")
        m.toggleApp("nope")
        m.systemUpdate = true
        check("network: picks work", m.desktop == "labwc" && m.apps == ["firefox", "vlc"] && m.chosenApps.map(\.id) == ["firefox", "vlc"])
        m.update(report: report { $0.caps.network = false })
        check("network lost: choices are cleared", m.desktop == nil && m.apps.isEmpty && !m.systemUpdate)
        m = model()
        m.chooseDesktop("labwc")
        m.chooseDesktop(AdditionsWizardModel.keepConsoleID)
        check("keep the console", m.desktop == nil)
        m.toggleApp("git")
        check("an installed app cannot be picked", m.apps.isEmpty && m.appChoices(group: "develop").first?.disabledReason == AdditionsText.installed)
        m = model()
        m.toggleApp("vlc")
        m.toggleApp("vlc")
        check("toggle off", m.apps.isEmpty)

        // The job from the choices, in the agent's order.
        m = model()
        m.password = "pw"
        m.confirm = "pw"
        m.hostName = "tuxbox"
        m.chooseDesktop("labwc")
        m.toggleApp("firefox")
        m.sshEnabled = true
        m.sshPasswordLogin = false
        m.sshKey = key + "\n"
        m.systemUpdate = true
        let j = m.job(id: "j-test")!
        check("job order", j.steps.map(\.action) == ["additions.install", "user.setup", "hostname.set", "desktop.install", "apps.install", "ssh.configure", "system.update"])
        check("job account", j.steps[1] == .userSetup(name: "tux", password: "pw", sudo: true, autologin: true, lockRoot: true))
        check("job ssh", j.steps[5] == .sshConfigure(enabled: true, port: 22, passwordAuth: false, rootLogin: false, authorizedKey: key))
        check("job id", j.id == "j-test" && m.job()?.id.hasPrefix("j-") == true)
        m.jobStarted()
        check("job started: the password leaves the model", m.password == "" && m.confirm == "" && m.step == .progress)
        m.jobFinished()
        check("job finished", m.step == .done)

        m = model()
        m.accountMode = .unchanged
        m.installAdditions = false
        check("nothing to do", m.jobSteps().isEmpty && m.job() == nil && m.problems(for: .review).contains { $0.contains("nothing to do") })
        m.accountMode = .new
        m.userName = "bob"
        m.autologin = false
        m.lockRoot = false
        m.sudo = false
        check("a new account", m.jobSteps() == [.userSetup(name: "bob", password: nil, sudo: false, autologin: false, lockRoot: false)])
        m = model { $0.hostname = "debian" }
        m.hostName = "debian"
        check("the same host name is no step", !m.jobSteps().contains { if case .hostnameSet = $0 { return true } else { return false } })
        m = model { $0.ssh = AdditionsSSH(); $0.ssh?.enabled = true; $0.ssh?.port = 2222 }
        check("ssh already on: defaults from the guest", m.sshEnabled && m.sshPortText == "2222" && m.sshPort == 2222)
        m.sshEnabled = false
        check("ssh turned off is a step", m.jobSteps().contains(.sshConfigure(enabled: false, port: 2222, passwordAuth: true, rootLogin: false, authorizedKey: nil)))

        // Checks.
        m = model()
        m.accountMode = .new
        m.userName = "Bad Name"
        m.step = .account
        check("bad user name blocks the account step", m.problems(for: .account).contains(AdditionsText.userNameRule) && !m.canGoNext)
        m.userName = "bob"
        m.password = "a"
        m.confirm = "b"
        check("password mismatch blocks", m.problems(for: .account) == [AdditionsText.passwordMismatch])
        m.confirm = "a"
        m.sudo = false
        check("no sudo and no root", m.problems(for: .account).count == 1 && m.problems(for: .account)[0].contains("No one could use root"))
        m.lockRoot = false
        check("no sudo, root left on: fine", m.problems(for: .account).isEmpty)
        m.hostName = "Bad_Host"
        check("bad host name", m.problems(for: .account) == [AdditionsText.hostNameRule])
        m.accountMode = .unchanged
        m.hostName = ""
        check("unchanged account: its fields are not checked", m.problems(for: .account).isEmpty)

        m = model()
        m.sshEnabled = true
        check("ssh with no key and no password is a lock-out", m.problems(for: .ssh).count == 1)
        m.password = "pw"
        m.confirm = "pw"
        check("ssh with a password login is fine", m.problems(for: .ssh).isEmpty)
        m.sshPasswordLogin = false
        check("ssh with password login off needs a key", m.problems(for: .ssh).count == 1)
        m.sshKey = "ssh-ed25519 bad"
        check("a bad key", m.problems(for: .ssh).contains(AdditionsText.keyRule))
        m.sshKey = key
        m.sshPortText = "70000"
        check("a bad port", m.problems(for: .ssh) == [AdditionsText.portRule])
        m.sshPortText = "2222"
        check("a good key and port", m.problems(for: .ssh).isEmpty && m.sshPort == 2222)
        m.sshEnabled = false
        m.sshPortText = "bad"
        check("ssh off: its fields are not checked", m.problems(for: .ssh).isEmpty)
        m = model()
        m.sshEnabled = true
        m.sshKey = key
        m.sshPasswordLogin = false
        check("a key makes password login optional", m.problems(for: .ssh).isEmpty)
        m.sshPortText = "0"
        check("review gathers problems", m.problems(for: .review).contains(AdditionsText.portRule) && m.job() == nil)

        // The port buttons.
        m = model()
        m.stepPort(1)
        check("port plus", m.sshPortText == "23")
        m.stepPort(-2)
        check("port minus", m.sshPortText == "21")
        m.sshPortText = "1"
        m.stepPort(-1)
        check("port stops at 1", m.sshPortText == "1")
        m.sshPortText = "65535"
        m.stepPort(1)
        check("port stops at 65535", m.sshPortText == "65535")
        m.sshPortText = "abc"
        m.stepPort(1)
        check("a bad text starts at the default port", m.sshPortText == "23")
        check("the buttons are 44 pt", AdditionsLayout.touchTarget >= 44)

        // The review.
        m = model()
        m.password = "secret-pw"
        m.confirm = "secret-pw"
        m.chooseDesktop("plasma")
        m.toggleApp("firefox")
        m.toggleApp("vlc")
        m.systemUpdate = true
        let lines = m.reviewLines
        check("review lines", lines.map(\.title) == ["Install Tuxedo Additions", "Account tux", "Set up KDE Plasma", "Install Firefox and VLC", "Update the system"])
        check("review of applications: no repeat of the title",
              lines[3].detail == "About 140 MB to download." && !lines[3].title.contains(lines[3].detail))
        m.toggleApp("chromium")
        let three = m.reviewLines[3]
        check("review of many applications names them", three.title == "Install 3 applications" && three.detail == "Firefox, Chromium, VLC")
        m.toggleApp("chromium")
        check("review account detail", lines[1].detail == "new password, sudo on, signs in automatically, root sign-in ends")
        check("review has no password", !lines.contains { $0.title.contains("secret-pw") || $0.detail.contains("secret-pw") })
        check("estimate", m.estimateMB == 1640 && m.estimateText == "About 1.6 GB to download, and the system updates.")
        check("no disk warning when it fits", m.warnings.isEmpty)
        m.chooseDesktop(AdditionsWizardModel.keepConsoleID)
        check("estimate without a desktop", m.estimateMB == 140)
        m = model { $0.diskFreeMB = 100 }
        m.chooseDesktop("plasma")
        check("not enough disk", m.warnings.contains("The machine has 100 MB free. This needs more."))
        m = model()
        m.autologin = false
        check("no password and no auto-login warns", m.warnings.contains(AdditionsText.noPasswordWarning))
        m.password = "x"
        m.confirm = "x"
        check("a password ends the warning", !m.warnings.contains(AdditionsText.noPasswordWarning))
        m = model()
        m.accountMode = .new
        m.userName = "bob"
        check("another name warns about ~/Tux", m.warnings.contains(AdditionsText.tuxMountNote))
        m = model { $0.network = false }
        check("no estimate without a network", m.estimateText == nil)

        // What blocks the wizard.
        m = model { $0.legacy = true }
        check("a legacy guest blocks", m.blocker == AdditionsText.legacyGuest && !m.canGoNext && m.job() == nil)
        m = AdditionsWizardModel(caps: report().caps, guestProtocol: 2, versions: versionSet, catalogue: catalogue)
        check("another protocol blocks", m.blocker == AdditionsText.protocolOld && !m.canGoNext)
        m.update(report: report())
        check("a report with the right protocol ends the block", m.blocker == nil && m.canGoNext)
        check("no report, no block", AdditionsWizardModel().blocker == nil)

        // The layout.
        let tile = AdditionsLayout.tileMinimum
        check("phone: two columns", Int((390 - 32 + 12) / (tile(390, 1) + 12)) == 2)
        check("tablet: three columns", Int((820 - 32 + 12) / (tile(820, 1) + 12)) == 3)
        check("wide: four columns at the content width", Int((960 - 32 + 12) / (tile(960, 1) + 12)) == 4)
        check("tiles are not under 140 pt, and larger text makes them wider", tile(300, 1) >= 140 && tile(390, 1.6) > tile(390, 1))
        check("a tile fits a narrow row", tile(200, 1.6) <= max(200 - 32, 140) && tile(0, 1) >= 140)
        check("touch targets", AdditionsLayout.touchTarget >= 44 && AdditionsLayout.primaryTarget >= 56)

        // The overview.
        let rows = model().overviewRows
        check("overview rows", rows.contains(.init(label: "Network", value: "On")) && rows.contains(.init(label: "Free disk", value: "1.8 GB"))
              && rows.contains(.init(label: "Tuxedo Additions", value: "guest 1.10.2, app 1.11.0"))
              && rows.contains(.init(label: "Account", value: "tux, no password")) && rows.contains(.init(label: "Console", value: "Root shell"))
              && rows.contains(.init(label: "Addresses", value: "10.0.2.15")) && rows.contains(.init(label: "SSH", value: "Not installed")))
    }

    // MARK: The password

    static func passwordHygiene() {
        var m = model()
        m.password = "hunter2-Passw0rd-xyz"
        m.confirm = "hunter2-Passw0rd-xyz"
        var dumped = ""
        dump(m, to: &dumped)
        let texts = ["\(m)", String(reflecting: m), String(describing: m), dumped, "\(Mirror(reflecting: m).children.map { "\($0.label ?? ""): \($0.value)" })"]
        check("the model shows no password", !texts.contains { $0.contains("hunter2") } && texts.allSatisfy { !$0.isEmpty })
        check("the description says a password is set", "\(m)".contains("hidden"))
        m.wipeSecrets()
        check("wipeSecrets empties both", m.password.isEmpty && m.confirm.isEmpty && "\(m)".contains("password: none"))
        m.password = "abc"
        m.confirm = "abc"
        m.jobFinished()
        check("a finished job empties them", m.password.isEmpty && m.confirm.isEmpty && m.step == .done)
    }

    // MARK: The account prompt

    static func trigger() {
        var t = AdditionsPolicy.Trigger()
        check("no report: no prompt", !t.shouldFire(report: nil, dismissed: false))
        check("configured: no prompt", !t.shouldFire(report: report { $0.caps.account?.configured = true }, dismissed: false))
        check("no account object: no prompt", !t.shouldFire(report: report { $0.caps.account = nil }, dismissed: false))
        check("configured unknown: no prompt", !t.shouldFire(report: report { $0.caps.account?.configured = nil }, dismissed: false))
        check("dismissed: no prompt", !t.shouldFire(report: report(), dismissed: true))
        check("legacy: no prompt", !t.shouldFire(report: report { $0.caps.legacy = true }, dismissed: false))
        check("another protocol: no prompt", !t.shouldFire(report: report { $0.protocolVersion = 2 }, dismissed: false))
        check("not configured: prompt", t.shouldFire(report: report(), dismissed: false))
        check("it fires once", !t.shouldFire(report: report(), dismissed: false) && t.fired)
        t.reset()
        check("a new session fires again", t.shouldFire(report: report(), dismissed: false))
        t.reset()
        t.consume()
        check("the wizard opened by hand ends the prompt", !t.shouldFire(report: report(), dismissed: false))

        let now = Date()
        check("nudge on a gap", AdditionsPolicy.shouldNudge(gap: true, inserted: true, jobRunning: false, lastNudge: nil, now: now))
        check("no nudge without a gap, an insert, or while a job runs",
              !AdditionsPolicy.shouldNudge(gap: false, inserted: true, jobRunning: false, lastNudge: nil, now: now)
              && !AdditionsPolicy.shouldNudge(gap: true, inserted: false, jobRunning: false, lastNudge: nil, now: now)
              && !AdditionsPolicy.shouldNudge(gap: true, inserted: true, jobRunning: true, lastNudge: nil, now: now))
        check("no second nudge at once", !AdditionsPolicy.shouldNudge(gap: true, inserted: true, jobRunning: false, lastNudge: now.addingTimeInterval(-5), now: now)
              && AdditionsPolicy.shouldNudge(gap: true, inserted: true, jobRunning: false, lastNudge: now.addingTimeInterval(-31), now: now))

        check("guest user: tux needs no record", AdditionsPolicy.guestUserUpdate(name: "tux", current: nil) == nil
              && AdditionsPolicy.guestUserUpdate(name: "tux", current: "tux") == nil)
        check("guest user: another name is saved", AdditionsPolicy.guestUserUpdate(name: "bob", current: "tux") == "bob"
              && AdditionsPolicy.guestUserUpdate(name: "bob", current: nil) == "bob" && AdditionsPolicy.guestUserUpdate(name: "bob", current: "bob") == nil)
        check("guest user: back to tux", AdditionsPolicy.guestUserUpdate(name: "tux", current: "bob") == "tux")
        check("bootstrap command", AdditionsPolicy.bootstrapCommand == "s=; [ \"$(id -u)\" = 0 ] || s=sudo; $s mkdir -p /mnt/tux && $s mount -t virtiofs -o ro tux-files /mnt/tux && $s sh /mnt/tux/tux-additions/install")
    }

    // MARK: The saved report

    static func savedReport() throws {
        var machine = VirtualMachine(name: "Debian", ramMB: 1024, diskBytes: 16 << 30)
        let bare = String(decoding: try JSONEncoder().encode(machine), as: UTF8.self)
        check("a missing report is not written", !bare.contains("additionsReport") && !bare.contains("additionsPromptDismissed"))
        let back = try JSONDecoder().decode(VirtualMachine.self, from: Data(bare.utf8))
        check("a missing report reads as unknown", back.additionsReport == nil && back.additionsPromptDismissed == nil && back == machine)

        machine.additionsReport = report()
        machine.additionsPromptDismissed = true
        let data = try JSONEncoder().encode([machine])
        let list = MachineList.decode(data, diskExists: { _ in true })!
        check("a report round-trips", list == [machine] && list[0].additionsReport?.caps.installed["tux-guest"] == "1.10.2"
              && list[0].additionsReport?.caps.account?.passwordSet == false && list[0].additionsReport?.protocolVersion == 1
              && list[0].additionsPromptDismissed == true)
        let written = String(decoding: data, as: UTF8.self)
        check("the report's wire names", written.contains("\"protocol\":1") && written.contains("\"password_set\":false") && written.contains("\"disk_free_mb\":1800"))

        let old = try JSONDecoder().decode(VirtualMachine.self, from: Data("""
        {"id":"11111111-2222-3333-4444-555555555555","name":"Old","ramMB":2048,"diskBytes":1,"added":1.5}
        """.utf8))
        check("a record from an older build reads", old.additionsReport == nil)

        let sparse = try JSONDecoder().decode(AdditionsReport.self, from: Data(#"{"t":"report","caps":{}}"#.utf8))
        check("a report with nothing in it", sparse.n == nil && sparse.caps.account == nil && sparse.caps.installed.isEmpty && !sparse.caps.network
              && sparse.caps.desktop == "none" && sparse.caps.ssh == nil)
        let odd = try JSONDecoder().decode(AdditionsReport.self, from: Data(#"{"n":"x","protocol":"1","caps":{"network":"yes","installed":{"tux-guest":7},"ips":3,"account":{"configured":"no"}}}"#.utf8))
        check("a value of the wrong type counts as missing", odd.n == nil && odd.protocolVersion == nil && !odd.caps.network && odd.caps.ips.isEmpty
              && odd.caps.account?.configured == nil)
        let nulls = report().caps.installed
        check("a null version is not installed", nulls["tux-codec-dkms"] == nil && nulls.count == 3)
    }

    // MARK: The reserved folder name

    static func reservedFolder() {
        check("tux-additions is taken", FolderPolicy.safeName("tux-additions", taken: []) == "tux-additions 2")
        check("tux-additions 2 may be taken too", FolderPolicy.safeName("tux-additions", taken: ["tux-additions 2"]) == "tux-additions 3")
        check("a name with a slash that makes it", FolderPolicy.safeName("tux/additions", taken: []) == "tux-additions 2")
        check("close names stay", FolderPolicy.safeName("tux-additions-2", taken: []) == "tux-additions-2" && FolderPolicy.safeName("Tux-Additions", taken: []) == "Tux-Additions")
        check("the reserved name", FolderPolicy.reservedName == "tux-additions")
    }
}
