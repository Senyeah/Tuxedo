import Foundation

/// The rules for a Linux machine's port forwards, and how the engine's state reads (tux_vm_forward_state).
enum ForwardPolicy {
    static let maxRules = 16
    /// iOS binds no port below 1024.
    static let phonePorts = 1024...65535
    static let guestPorts = 1...65535
    static let sshPhonePort = 2222

    /// The one-tap rule: 2222 on the phone to the guest's sshd.
    static func sshPreset() -> PortForward { PortForward(name: "SSH", phonePort: sshPhonePort, guestPort: 22) }

    static func canAddSSH(_ list: [PortForward]) -> Bool {
        list.count < maxRules && !list.contains {
            $0.phonePort == sshPhonePort || ($0.guestPort == 22 && cleanName($0.name ?? "")?.caseInsensitiveCompare("SSH") == .orderedSame)
        }
    }

    /// A typed name as stored: trimmed, nil when blank.
    static func cleanName(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// A typed port, or nil for a blank or non-numeric field (the rule keeps its port).
    static func port(_ text: String) -> Int? { Int(text.trimmingCharacters(in: .whitespaces)) }

    /// A new rule: the first free phone port from 8000, to the same port in the guest.
    static func newRule(_ list: [PortForward]) -> PortForward {
        let taken = Set(list.map(\.phonePort))
        let port = (8000...phonePorts.upperBound).first { !taken.contains($0) } ?? 8000
        return PortForward(phonePort: port, guestPort: port)
    }

    enum Problem: Equatable {
        case phonePort, guestPort, duplicate
    }

    /// What is wrong with rule i: a port out of range, or a phone port an earlier rule has (enabled or not).
    static func problem(_ list: [PortForward], at i: Int) -> Problem? {
        let f = list[i]
        if !phonePorts.contains(f.phonePort) { return .phonePort }
        if !guestPorts.contains(f.guestPort) { return .guestPort }
        if list[..<i].contains(where: { $0.phonePort == f.phonePort }) { return .duplicate }
        return nil
    }

    static func problemText(_ p: Problem) -> String {
        switch p {
        case .phonePort: return "The phone port must be from 1024 to 65535: iOS does not allow lower ones."
        case .guestPort: return "The guest port must be from 1 to 65535."
        case .duplicate: return "Another forward has this phone port."
        }
    }

    static func isValid(_ list: [PortForward]) -> Bool {
        list.count <= maxRules && list.indices.allSatisfy { problem(list, at: $0) == nil }
    }

    /// What the engine gets: the enabled rules with no problem, at most maxRules.
    static func active(_ list: [PortForward]) -> [PortForward] {
        Array(list.prefix(maxRules).indices.filter { list[$0].enabled && problem(list, at: $0) == nil }.map { list[$0] })
    }

    static func title(_ f: PortForward) -> String {
        if let n = cleanName(f.name ?? "") { return n }
        return "Port \(f.guestPort)"
    }

    /// What another device uses to connect: an ssh command for the guest's port 22, else address:port.
    static func connectText(_ f: PortForward, address: String, user: String) -> String {
        f.guestPort == 22 ? "ssh -p \(f.phonePort) \(user)@\(address)" : "\(address):\(f.phonePort)"
    }

    struct Address: Hashable {
        var ip: String
        var interface: String
        var isLoopback: Bool { interface.hasPrefix("lo") || ip.hasPrefix("127.") }
    }

    static func networkName(_ interface: String) -> String {
        if interface == "en0" { return "Wi-Fi" }
        if interface.hasPrefix("en") { return "Ethernet" }
        if interface.hasPrefix("bridge") { return "Personal Hotspot" }
        if interface.hasPrefix("utun") { return "VPN" }
        if interface.hasPrefix("lo") { return "This device" }
        return interface
    }

    /// tux_vm_forward_state's "IP IFNAME" lines, local networks first (Wi-Fi, Ethernet, hotspot, VPN) and loopback last.
    static func parseAddresses(_ text: String) -> [Address] {
        let rank = { (a: Address) -> Int in
            a.isLoopback ? 9 : a.interface == "en0" ? 0 : a.interface.hasPrefix("en") ? 1 : a.interface.hasPrefix("bridge") ? 2 : 3
        }
        let list = text.split(separator: "\n").compactMap { line -> Address? in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let ip = parts.first, !ip.isEmpty else { return nil }
            return Address(ip: ip, interface: parts.count > 1 ? parts[1] : "")
        }
        return list.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    enum Shown: Equatable {
        /// The machine is not running, or its network has not taken the rule yet.
        case off
        /// Where another device connects; loopback only for a client on this device.
        case listening(local: [Address], loopback: Bool)
        /// Cellular only: nothing else can reach it.
        case noLocalNetwork(loopback: Bool)
        case failed(String, local: [Address])
    }

    static let addressInUse: Int32 = 48 // EADDRINUSE on Darwin

    /// One rule's state from tux_vm_forward_state's count, errno and lines.
    static func shown(count: Int32, err: Int32, text: String, phonePort: Int, device: String) -> Shown {
        guard count >= 0 else { return .off }
        let all = parseAddresses(text)
        let local = all.filter { !$0.isLoopback }
        if err != 0 {
            let somewhere = local.isEmpty ? "" : " on some of its addresses"
            let why = err == addressInUse ? "Port \(phonePort) is in use on this \(device)\(somewhere)."
                : "Port \(phonePort) cannot be opened (\(String(cString: strerror(err))))."
            return .failed(why, local: local)
        }
        if local.isEmpty { return .noLocalNetwork(loopback: all.contains { $0.isLoopback }) }
        return .listening(local: local, loopback: all.contains { $0.isLoopback })
    }

    static let noLocalNetworkText = "No local network. Join Wi-Fi or a VPN, or connect Ethernet, to reach this port from another device."
}
