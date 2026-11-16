// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The rules for Tuxedo Additions (docs/guest-additions-design.md), with no UIKit and no engine, so
/// tests/test_additions_policy.swift can check them: version order, the checks on what a person types, the
/// account prompt, and the texts.
enum AdditionsPolicy {
    /// The wire protocol this app speaks (actions.json "protocol").
    static let protocolVersion = 1
    /// The account name the images ship, and the one the guest's ~/Tux mount uses.
    static let defaultUser = "tux"

    // MARK: Versions

    /// Debian's order (dpkg --compare-versions): epoch, then upstream, then revision; "~" sorts before the end.
    /// 9.0.2-tux2 is before 9.0.2-tux10. Returns -1, 0 or 1.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let (ea, ua, ra) = split(a), (eb, ub, rb) = split(b)
        if ea != eb { return ea < eb ? -1 : 1 }
        let upstream = compareParts(ua, ub)
        return upstream != 0 ? upstream : compareParts(ra, rb)
    }

    private static func split(_ v: String) -> (epoch: Int, upstream: [UInt8], revision: [UInt8]) {
        var rest = Substring(v.trimmingCharacters(in: .whitespaces))
        var epoch = 0
        if let colon = rest.firstIndex(of: ":"), let e = Int(rest[..<colon]), e >= 0 {
            epoch = e
            rest = rest[rest.index(after: colon)...]
        }
        guard let dash = rest.lastIndex(of: "-") else { return (epoch, Array(rest.utf8), []) }
        return (epoch, Array(rest[..<dash].utf8), Array(rest[rest.index(after: dash)...].utf8))
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    /// The rank of a character that is not a digit: "~" first, then the end, then letters, then the rest.
    private static func order(_ c: UInt8?) -> Int {
        guard let c else { return 0 }
        if isDigit(c) { return 0 }
        if c == 126 { return -1 } // ~
        if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) { return Int(c) }
        return Int(c) + 256
    }

    private static func compareParts(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var i = 0, j = 0
        while i < a.count || j < b.count {
            while (i < a.count && !isDigit(a[i])) || (j < b.count && !isDigit(b[j])) {
                let x = order(i < a.count ? a[i] : nil), y = order(j < b.count ? b[j] : nil)
                if x != y { return x < y ? -1 : 1 }
                i += 1
                j += 1
            }
            while i < a.count && a[i] == 48 { i += 1 }
            while j < b.count && b[j] == 48 { j += 1 }
            var first = 0
            while i < a.count && j < b.count && isDigit(a[i]) && isDigit(b[j]) {
                if first == 0 { first = Int(a[i]) - Int(b[j]) }
                i += 1
                j += 1
            }
            if i < a.count && isDigit(a[i]) { return 1 }
            if j < b.count && isDigit(b[j]) { return -1 }
            if first != 0 { return first < 0 ? -1 : 1 }
        }
        return 0
    }

    /// The packages of the app's set that the guest has in an older version. A package the guest does not have is
    /// not in the list: that is "not installed", not "older".
    static func outdated(installed: [String: String], bundled: [String: String]) -> [String] {
        bundled.keys.sorted().filter { name in
            guard let have = installed[name], let want = bundled[name] else { return false }
            return compareVersions(have, want) < 0
        }
    }

    /// The packages of the app's set that the guest lacks. An optional package (the install skips it on a stock
    /// image) is not "missing".
    static func missing(installed: [String: String], bundled: [String: String],
                        optional: Set<String> = AdditionsVersions.defaultOptional) -> [String] {
        bundled.keys.sorted().filter { installed[$0] == nil && !optional.contains($0) }
    }

    /// One package the tools step would change.
    struct Change: Equatable {
        var name: String
        /// nil: not installed.
        var from: String?
        var to: String
    }

    /// The packages the step would change, by name: the missing ones and the older ones. A current package is not here.
    static func changes(installed: [String: String], bundled: [String: String],
                        optional: Set<String> = AdditionsVersions.defaultOptional) -> [Change] {
        let old = Set(outdated(installed: installed, bundled: bundled))
        let lacking = Set(missing(installed: installed, bundled: bundled, optional: optional))
        return bundled.keys.sorted().filter { old.contains($0) || lacking.contains($0) }.map {
            Change(name: $0, from: installed[$0], to: bundled[$0] ?? "")
        }
    }

    /// The banner in Details: never for a legacy guest, and only when a package is older than the app's set.
    static func updateAvailable(_ caps: AdditionsCaps?, versions: AdditionsVersions?) -> Bool {
        guard let caps, let versions, !caps.legacy else { return false }
        return !outdated(installed: caps.installed, bundled: versions.packages).isEmpty
    }

    /// The guest's tux-guest version, for the state rows.
    static func guestVersion(_ caps: AdditionsCaps?) -> String? { caps?.installed["tux-guest"] }

    static func protocolSupported(_ report: AdditionsReport?) -> Bool {
        guard let p = report?.protocolVersion else { return true }
        return p == protocolVersion
    }

    // MARK: What a person types

    static let userNameMaxBytes = 32
    static let hostNameMaxBytes = 63
    static let keyMaxBytes = 4096
    static let passwordMaxBytes = 128
    static let keyTypes = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
                           "ssh-rsa", "sk-ssh-ed25519@openssh.com"]

    // Written with characters, not a regular expression: ICU's "$" also matches before a final newline.
    private static func isLower(_ c: UInt8) -> Bool { c >= 97 && c <= 122 }
    private static func isAlnum(_ c: UInt8) -> Bool { isLower(c) || isDigit(c) }

    /// ^[a-z_][a-z0-9_-]{0,31}$
    static func validUserName(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard (1...userNameMaxBytes).contains(b.count), isLower(b[0]) || b[0] == 95 else { return false }
        return b.dropFirst().allSatisfy { isAlnum($0) || $0 == 95 || $0 == 45 }
    }

    /// ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$
    static func validHostName(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard (1...hostNameMaxBytes).contains(b.count), isAlnum(b[0]), isAlnum(b[b.count - 1]) else { return false }
        return b.allSatisfy { isAlnum($0) || $0 == 45 }
    }

    /// 1 to 65535, digits only.
    static func port(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.utf8.count <= 5, t.utf8.allSatisfy(isDigit), let p = Int(t) else { return nil }
        return validPort(p) ? p : nil
    }

    static func validPort(_ p: Int, range: ClosedRange<Int> = 1...65535) -> Bool { range.contains(p) }

    /// What a paste leaves around a key: spaces and the final newline.
    static func trimmedKey(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The same check as the agent's check_key (tools/linux/additions/agent): "type base64 [comment]" on one line, 4 KB
    /// at most, ASCII 0x20 to 0x7e only, a base64 body that decodes to length-prefixed fields that use every byte, and
    /// a first field that is the declared type.
    static func validAuthorizedKey(_ raw: String) -> Bool {
        let s = trimmedKey(raw)
        let bytes = Array(s.utf8)
        guard !bytes.isEmpty, bytes.count <= keyMaxBytes, bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { return false }
        let parts = s.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, keyTypes.contains(String(parts[0])), let blob = decodeBase64(parts[1]) else { return false }
        var fields: [ArraySlice<UInt8>] = []
        var at = 0
        while at < blob.count {
            guard at + 4 <= blob.count else { return false }
            let n = blob[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
            guard at + 4 + n <= blob.count else { return false }
            fields.append(blob[at + 4..<at + 4 + n])
            at += 4 + n
        }
        let type = String(parts[0])
        let count = ["ssh-ed25519": 2, "sk-ssh-ed25519@openssh.com": 3, "ssh-rsa": 3][type] ?? 3
        guard fields.count == count, Array(fields[0]) == Array(type.utf8) else { return false }
        return type != "ssh-ed25519" || fields[1].count == 32
    }

    /// Base64 with the padding it needs and no other character: [A-Za-z0-9+/]+={0,2}, a length that is a multiple of 4.
    private static func decodeBase64(_ body: Substring) -> [UInt8]? {
        let b = Array(body.utf8)
        guard b.count >= 4, b.count % 4 == 0 else { return nil }
        let pad = b.reversed().prefix { $0 == 61 }.count
        guard pad <= 2 else { return nil }
        var out: [UInt8] = []
        var acc = 0, bits = 0
        for c in b.dropLast(pad) {
            let v: Int
            switch c {
            case 65...90: v = Int(c) - 65
            case 97...122: v = Int(c) - 71
            case 48...57: v = Int(c) + 4
            case 43: v = 62
            case 47: v = 63
            default: return nil
            }
            acc = (acc << 6 | v) & 0xffff
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> bits) & 0xff))
            }
        }
        return out
    }

    /// The app's own limits on a new password: it goes to chpasswd as one line.
    static func passwordProblem(_ password: String, confirm: String) -> String? {
        guard !password.isEmpty else { return nil }
        if password.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) { return AdditionsText.passwordControl }
        if password.utf8.count > passwordMaxBytes { return AdditionsText.passwordLong }
        if password != confirm { return AdditionsText.passwordMismatch }
        return nil
    }

    // MARK: The account prompt

    /// What the guest's user name becomes after a job made the account. nil: the record stays as it is. The images'
    /// own name needs no entry in a record that has none; an account with another name does.
    static func guestUserUpdate(name: String, current: String?) -> String? {
        if name == defaultUser { return current != nil && current != defaultUser ? defaultUser : nil }
        return name == current ? nil : name
    }

    /// Once for each session of a machine: when a report says the account is not set up and the person has not
    /// said Not now. A guest that sends no account object, or a legacy guest, never starts it.
    struct Trigger {
        private(set) var fired = false

        mutating func shouldFire(report: AdditionsReport?, dismissed: Bool) -> Bool {
            guard !fired, !dismissed, let report, protocolSupported(report), !report.caps.legacy,
                  report.caps.account?.configured == false else { return false }
            fired = true
            return true
        }

        mutating func reset() { fired = false }

        /// The person opened the wizard by hand: the prompt has nothing left to ask.
        mutating func consume() { fired = true }
    }

    /// A job with no account step, started on a machine whose account is not set up: the person chose "Leave as it is".
    /// The prompt must not come back for this machine.
    static func leavesAccountUnset(job accountName: String?, caps: AdditionsCaps?) -> Bool {
        accountName == nil && caps?.account?.configured == false
    }

    /// A gap means the app missed events. It asks the agent for a new report with a nudge, which restarts the
    /// agent: never while a job runs, and not twice in a row within `every` seconds.
    static func shouldNudge(gap: Bool, inserted: Bool, jobRunning: Bool, lastNudge: Date?, now: Date, every: TimeInterval = 30) -> Bool {
        guard gap, inserted, !jobRunning else { return false }
        guard let lastNudge else { return true }
        return now.timeIntervalSince(lastNudge) >= every
    }

    /// 20 s with no report, then the commands.
    static let connectWait: TimeInterval = 20

    /// No ack and no step 90 s after Start: the agent is not there. The app cancels the job.
    static let jobStartTimeout: TimeInterval = 90

    /// The bootstrap for a guest with no tux-guest (design 6).
    static let bootstrapCommand = "s=; [ \"$(id -u)\" = 0 ] || s=sudo; $s mkdir -p /mnt/tux && $s mount -t virtiofs -o ro tux-files /mnt/tux && $s sh /mnt/tux/tux-additions/install"
}

/// The texts of Tuxedo Additions, short, in Simplified Technical English.
enum AdditionsText {
    static let sectionTitle = "Tuxedo Additions"
    static let insert = "Insert Tuxedo Additions CD"
    static let eject = "Eject Tuxedo Additions CD"
    /// For a button that has little room; its accessibility label stays the full one.
    static let ejectShort = "Eject CD"
    static let open = "Open Tuxedo Additions"
    static let detailsNote = "Tuxedo Additions sets up the machine: the account, a desktop, applications and SSH. The app does the work through a small agent in the guest."
    static let notInThisApp = "This build has no Additions media."
    static let noReport = "No report yet"
    static let notInstalled = "Not installed"
    static let legacyGuest = "This is an older machine. It does not use Tuxedo Additions."
    static let updateBanner = "The guest has an older version. Open Tuxedo Additions to update it."
    static let protocolOld = "The guest uses a different protocol. Update Tuxedo and insert the CD again."
    static let badMedia = "The guest did not accept the media. Eject the CD and insert it again."

    static let noNetwork = "No network. Connect the machine to a network first."
    static let installed = "Installed"
    static let current = "In use"
    static let needsNetwork = "Needs network"

    static let passwordMismatch = "The two passwords are not the same."
    static let passwordControl = "A password cannot hold a line break or a control character."
    static let passwordLong = "A password can have 128 bytes at most."
    static let userNameRule = "Use lower-case letters, digits, - and _. Start with a letter or _. 32 characters at most."
    static let hostNameRule = "Use lower-case letters, digits and -. Start and end with a letter or a digit. 63 characters at most."
    static let portRule = "Use a number from 1 to 65535."
    static let keyRule = "Paste one public key on one line. It starts with ssh-ed25519, ecdsa-sha2-nistp256, ssh-rsa or a similar type."
    static let noPasswordWarning = "With no password and no automatic sign-in, the sign-in prompt accepts an empty password."

    static let rootShellNote = "Until this step runs, the console is a root shell."
    static let promptTitle = "This machine has no account yet"
    static let promptBody = "Set it up now? You choose a name and a password. The console then stops signing in as root."
    static let promptSetUp = "Set up"
    static let promptNotNow = "Not now"

    static let autologinNote = "The console opens as this account with no password."
    static let sudoNote = "The account can run commands as root with sudo."
    static let lockRootNote = "Root cannot sign in at the console. Use sudo from the account."
    static let tuxMountNote = "The ~/Tux folder still uses /home/tux."

    static let connectWaiting = "Waiting for the guest. Tuxedo Additions starts by itself when the guest has tux-guest 1.11 or newer."
    static let connectBootstrap = "The guest does not answer. It may not have tux-guest. Run this command in the guest. It uses sudo when you are not root."
    static let typeCommands = "Type the commands"
    static let copyCommands = "Copy"
    static let restartToggle = "The new desktop starts after the restart. Turn this off to restart the machine yourself later."
    static let restartingNote = "The machine restarts in a moment to start the new desktop."
    static let restartNote = "Restart the machine to use the new desktop and settings."
    static let reviewNote = "Pressing Start sends these choices to the machine. Keep Tuxedo open while it works."
    static let introPoints = [
        "Account: a name, a password, sudo and how the console signs in.",
        "Desktop and applications: Debian installs them. This needs a network.",
        "SSH: sign in to the machine from another computer.",
        "Nothing changes until you press Start on the last step.",
    ]
    static let desktopPoints = [
        "The console is small and fast. It has no windows.",
        "A desktop adds windows, a panel and a menu. It takes more disk and more memory.",
        "The sizes are the download. The machine needs more free disk than that.",
        "The machine restarts to start a new desktop. You can switch desktops again later.",
    ]
    static let sshPoints = [
        "SSH lets you sign in from another computer. It is off until you turn it on.",
        "Tuxedo shows the host key fingerprints when the job ends.",
        "To reach the machine from outside, add a port forward in Details.",
    ]
    static let waitingForAgent = "Waiting for the agent in the guest…"
    static let cancelled = "The job was cancelled."
    static let noAnswer = "The guest did not answer."
    static let noAnswerHelp = "The job did not start. Check that the machine runs, then try again."
    static let notInserted = "The Tuxedo Additions CD is not in. Insert it and try again."
}
