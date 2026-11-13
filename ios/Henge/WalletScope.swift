import Foundation

/// How a Linux machine's wallet items are named in the Keychain (KeychainStore): one Keychain service per machine,
/// so two machines never see each other's items. The account is the item's id from the guest (host/secrets.c).
enum WalletScope {
    static let servicePrefix = "com.henge.linux-wallet."

    /// The scope host/secrets.c gets: [a-z0-9-], 36 characters.
    static func id(_ machine: UUID) -> String { machine.uuidString.lowercased() }
    static func service(_ machine: UUID) -> String { servicePrefix + id(machine) }

    /// The machine a Keychain service belongs to, or nil for another service.
    static func machine(service: String) -> UUID? {
        guard service.hasPrefix(servicePrefix) else { return nil }
        return UUID(uuidString: String(service.dropFirst(servicePrefix.count)))
    }
}
