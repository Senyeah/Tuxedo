// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The job the app gives the guest's agent (docs/guest-additions-design.md, 5.5). The password is in the JSON that
/// goes to the engine and nowhere else: no description, no log line.
struct AdditionsJob: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum Step: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        case additionsInstall
        case userSetup(name: String, password: String?, sudo: Bool, autologin: Bool, lockRoot: Bool)
        case hostnameSet(name: String)
        case desktopInstall(id: String)
        case appsInstall(ids: [String])
        case sshConfigure(enabled: Bool, port: Int, passwordAuth: Bool, rootLogin: Bool, authorizedKey: String?)
        case systemUpdate

        var action: String {
            switch self {
            case .additionsInstall: return "additions.install"
            case .userSetup: return "user.setup"
            case .hostnameSet: return "hostname.set"
            case .desktopInstall: return "desktop.install"
            case .appsInstall: return "apps.install"
            case .sshConfigure: return "ssh.configure"
            case .systemUpdate: return "system.update"
            }
        }

        /// The action only: a step can hold a password, and print, dump and logs must not show it.
        var description: String { action }
        var debugDescription: String { action }
        var customMirror: Mirror { Mirror(self, children: ["action": action]) }

        fileprivate var object: [String: Any] {
            var o: [String: Any] = ["action": action]
            switch self {
            case .additionsInstall, .systemUpdate:
                break
            case let .userSetup(name, password, sudo, autologin, lockRoot):
                o["name"] = name
                if let password, !password.isEmpty { o["password"] = password }
                o["sudo"] = sudo
                o["autologin"] = autologin
                o["lock_root"] = lockRoot
            case .hostnameSet(let name):
                o["name"] = name
            case .desktopInstall(let id):
                o["id"] = id
            case .appsInstall(let ids):
                o["ids"] = ids
            case let .sshConfigure(enabled, port, passwordAuth, rootLogin, key):
                o["enabled"] = enabled
                o["port"] = port
                o["password_auth"] = passwordAuth
                o["root_login"] = rootLogin
                if let key, !key.isEmpty { o["authorized_key"] = key }
            }
            return o
        }

        /// A line for the progress list.
        func title(_ catalogue: AdditionsCatalogue?) -> String {
            switch self {
            case .additionsInstall: return "Install Tuxedo Additions"
            case .userSetup: return "Set up the account"
            case .hostnameSet: return "Set the machine name"
            case .desktopInstall(let id): return "Set up \(catalogue?.desktop(id)?.title ?? id)"
            case .appsInstall(let ids):
                let names = ids.map { catalogue?.app($0)?.title ?? $0 }
                return ids.count <= 2 ? "Install " + names.joined(separator: " and ") : "Install \(ids.count) applications"
            case .sshConfigure(let enabled, _, _, _, _): return enabled ? "Set up SSH" : "Turn SSH off"
            case .systemUpdate: return "Update the system"
            }
        }
    }

    var id: String
    var steps: [Step]
    /// The guest restarts when the job ends well (a new desktop needs it).
    var rebootAfter = false

    static let maxBytes = 16 * 1024

    /// "j-" and 8 hex digits.
    static func newID() -> String { "j-" + String(format: "%08x", UInt32.random(in: 0...UInt32.max)) }

    /// The JSON for hv_additions_job_set, ending in a zero byte so the caller can pass it as a C string and wipe it
    /// after. nil when the job is empty or over the 16 KB limit. The Data of the serializer is zeroed here: the caller
    /// wipes the returned array, and these two are the only copies of the bytes that Swift lets the app reach.
    func jsonBytes() -> [UInt8]? {
        guard !steps.isEmpty else { return nil }
        var object: [String: Any] = ["id": id, "steps": steps.map(\.object)]
        if rebootAfter { object["reboot_after"] = true }
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        defer { data.resetBytes(in: 0..<data.count) }
        guard data.count <= Self.maxBytes else { return nil }
        var bytes = [UInt8](repeating: 0, count: data.count + 1) // one array: no growth, so no stale copy
        data.copyBytes(to: &bytes, count: data.count)
        return bytes
    }

    /// The same as text.
    func json() -> String? { jsonBytes().map { String(decoding: $0.dropLast(), as: UTF8.self) } }

    /// The account the job makes or changes.
    var accountName: String? {
        for case let .userSetup(name, _, _, _, _) in steps { return name }
        return nil
    }

    /// The index of the step that sets up the account.
    var accountStepIndex: Int? { steps.firstIndex { if case .userSetup = $0 { return true } else { return false } } }

    var description: String { "job \(id), \(steps.count) steps" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["id": id, "steps": steps.map(\.action)]) }
}
