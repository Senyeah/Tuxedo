import Foundation
import Security

/// A Linux machine's wallet in the iOS Keychain: the store behind host/secrets.c, so items that henge-secrets
/// keeps in the guest (Secret Service and KWallet) are Keychain items of this app.
///
/// - One Keychain service per machine (WalletScope); the account is the guest's item id. kSecAttrGeneric holds the
///   item's metadata (labels, attributes); kSecValueData holds the secret.
/// - This device only, while it is unlocked, and never in iCloud Keychain. The items have no Face ID rule of their
///   own: the session's Face ID gate (SessionGate) is the lock. While it is shut, the store answers "locked" for a
///   secret and still lists the metadata. (An item rule refused even the listing without a new prompt: -25308.)
/// - The share server's threads call in, one call at a time (secrets.c).
final class KeychainStore {
    static let shared = KeychainStore()

    private let lock = NSLock()
    private var unlocked = false

    /// The machine the guest's wallet is for; nil for a Mac, which has no wallet.
    func attach(_ mac: VirtualMac) {
        var store = HvSecretStore(ctx: nil, list: storeList, read: storeRead, write: storeWrite, remove: storeRemove)
        if mac.guest == .linux {
            Self.dropOldLayout(machine: mac.id)
            henge_vm_secrets(&store, WalletScope.id(mac.id))
        } else {
            henge_vm_secrets(nil, nil)
        }
    }

    /// The session's check passed, or the wallet locks: in the background, or when the session ends.
    func setUnlocked(_ unlocked: Bool) {
        lock.lock()
        self.unlocked = unlocked
        lock.unlock()
        henge_vm_secrets_set_locked(unlocked ? 0 : 1)
    }

    private var isLocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !unlocked
    }

    /// A deleted machine's items go with it.
    static func removeAll(machine: UUID) {
        for service in [WalletScope.service(machine), WalletScope.oldService(machine)] {
            let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                        kSecUseDataProtectionKeychain: true] as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { HengeLog.log("wallet", "remove all: \(status)") }
        }
    }

    /// Once for each machine: the items of the first layout had a Face ID rule each, so they could not be listed.
    private static func dropOldLayout(machine: UUID) {
        let done = "walletOldLayoutDropped." + WalletScope.id(machine)
        guard !UserDefaults.standard.bool(forKey: done) else { return }
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: WalletScope.oldService(machine),
                                    kSecUseDataProtectionKeychain: true] as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            if status == errSecSuccess { HengeLog.log("wallet", "removed the items of the old layout") }
            UserDefaults.standard.set(true, forKey: done)
        } else {
            HengeLog.log("wallet", "old layout: keychain status \(status)") // tried again at the next start
        }
    }

    private func base(_ scope: String, _ id: String? = nil) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: WalletScope.servicePrefix + scope,
                                  kSecUseDataProtectionKeychain: true, kSecAttrSynchronizable: false]
        if let id { q[kSecAttrAccount] = id }
        return q
    }

    private static func code(_ status: OSStatus, _ op: String) -> Int32 {
        switch status {
        case errSecSuccess: return Int32(HV_SECRET_OK)
        case errSecItemNotFound: return Int32(HV_SECRET_NOT_FOUND)
        default:
            HengeLog.log("wallet", "\(op): keychain status \(status)") // a status code only, never an item
            // The phone's own lock (protected data unavailable) reads as locked.
            return status == errSecInteractionNotAllowed ? Int32(HV_SECRET_LOCKED) : Int32(HV_SECRET_FAILED)
        }
    }

    fileprivate func list(_ scope: String, _ each: (String, Data) -> Void) -> Int32 {
        var q = base(scope)
        q[kSecMatchLimit] = kSecMatchLimitAll
        q[kSecReturnAttributes] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess else { return Self.code(status, "list") }
        for item in result as? [[CFString: Any]] ?? [] {
            guard let id = item[kSecAttrAccount] as? String else { continue }
            each(id, item[kSecAttrGeneric] as? Data ?? Data())
        }
        return Int32(HV_SECRET_OK)
    }

    fileprivate func read(_ scope: String, _ id: String) -> (Int32, Data?) {
        guard !isLocked else { return (Int32(HV_SECRET_LOCKED), nil) }
        var q = base(scope, id)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        return (Self.code(status, "read"), result as? Data)
    }

    fileprivate func write(_ scope: String, _ id: String, meta: Data, secret: Data) -> Int32 {
        guard !isLocked else { return Int32(HV_SECRET_LOCKED) }
        let status = SecItemUpdate(base(scope, id) as CFDictionary, [kSecAttrGeneric: meta, kSecValueData: secret] as CFDictionary)
        guard status == errSecItemNotFound else { return Self.code(status, "update") }
        var add = base(scope, id)
        add[kSecAttrGeneric] = meta
        add[kSecValueData] = secret
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return Self.code(SecItemAdd(add as CFDictionary, nil), "add")
    }

    fileprivate func remove(_ scope: String, _ id: String) -> Int32 {
        guard !isLocked else { return Int32(HV_SECRET_LOCKED) }
        return Self.code(SecItemDelete(base(scope, id) as CFDictionary), "remove")
    }
}

// The C side's calls (secrets.h). Strings and buffers are only valid during the call.

private let storeList: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, HvSecretItemFn?, UnsafeMutableRawPointer?) -> Int32 = { _, scope, fn, arg in
    guard let scope, let fn else { return Int32(HV_SECRET_FAILED) }
    return KeychainStore.shared.list(String(cString: scope)) { id, meta in
        id.withCString { cid in meta.withUnsafeBytes { fn(arg, cid, $0.baseAddress, meta.count) } }
    }
}

private let storeRead: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
                                       UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutablePointer<Int>?) -> Int32 = { _, scope, id, out, len in
    guard let scope, let id, let out, let len else { return Int32(HV_SECRET_FAILED) }
    let (code, data) = KeychainStore.shared.read(String(cString: scope), String(cString: id))
    guard code == Int32(HV_SECRET_OK), let data else { return code == Int32(HV_SECRET_OK) ? Int32(HV_SECRET_FAILED) : code }
    guard let copy = malloc(max(data.count, 1)) else { return Int32(HV_SECRET_FAILED) }
    data.withUnsafeBytes { if let p = $0.baseAddress { memcpy(copy, p, data.count) } }
    out.pointee = copy
    len.pointee = data.count
    return code
}

private let storeWrite: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeRawPointer?, Int,
                                        UnsafeRawPointer?, Int) -> Int32 = { _, scope, id, meta, metaLen, secret, len in
    guard let scope, let id else { return Int32(HV_SECRET_FAILED) }
    let m = meta.map { Data(bytes: $0, count: metaLen) } ?? Data()
    let s = secret.map { Data(bytes: $0, count: len) } ?? Data()
    return KeychainStore.shared.write(String(cString: scope), String(cString: id), meta: m, secret: s)
}

private let storeRemove: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, scope, id in
    guard let scope, let id else { return Int32(HV_SECRET_FAILED) }
    return KeychainStore.shared.remove(String(cString: scope), String(cString: id))
}
