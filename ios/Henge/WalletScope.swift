import Foundation

/// How a Linux machine's wallet items are named in the Keychain (KeychainStore): one Keychain service per machine,
/// so two machines never see each other's items. The account is the item's id from the guest (host/secrets.c).
enum WalletScope {
    static let servicePrefix = "com.henge.linux-wallet.v2."
    /// The first layout, whose items had a Face ID rule each (KeychainStore.dropOldLayout).
    static let oldServicePrefix = "com.henge.linux-wallet."

    /// The scope host/secrets.c gets: [a-z0-9-], 36 characters.
    static func id(_ machine: UUID) -> String { machine.uuidString.lowercased() }
    static func service(_ machine: UUID) -> String { servicePrefix + id(machine) }
    static func oldService(_ machine: UUID) -> String { oldServicePrefix + id(machine) }
}
