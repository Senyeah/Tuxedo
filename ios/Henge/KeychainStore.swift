import Foundation
import LocalAuthentication
import Security

/// A Linux machine's wallet in the iOS Keychain: the store behind host/secrets.c, so items that henge-secrets
/// keeps in the guest (Secret Service and KWallet) are Keychain items of this app.
///
/// - One Keychain service per machine (WalletScope); the account is the guest's item id. kSecAttrGeneric holds the
///   item's metadata (labels, attributes), which needs no Face ID to read; kSecValueData holds the secret.
/// - This device only, while it is unlocked, and never in iCloud Keychain. Reading or changing an item needs the
///   context of the session's Face ID check (SessionAuth); without one, the store answers "locked".
/// - The share server's threads call in, one call at a time (secrets.c).
final class KeychainStore {
    static let shared = KeychainStore()

    private let lock = NSLock()
    private var context: LAContext?
    private var unlocked = false

    /// The machine the guest's wallet is for; nil for a Mac, which has no wallet.
    func attach(_ mac: VirtualMac) {
        var store = HvSecretStore(ctx: nil, list: storeList, read: storeRead, write: storeWrite, remove: storeRemove)
        if mac.guest == .linux {
            henge_vm_secrets(&store, WalletScope.id(mac.id))
        } else {
            henge_vm_secrets(nil, nil)
        }
    }

    /// The session's check passed (context) or the wallet locks (nil): in the background, or when the session ends.
    func setUnlocked(_ unlocked: Bool, context: LAContext?) {
        lock.lock()
        if !unlocked { self.context?.invalidate() }
        self.context = unlocked ? context : nil
        self.unlocked = unlocked
        lock.unlock()
        henge_vm_secrets_set_locked(unlocked ? 0 : 1)
    }

    /// A deleted machine's items go with it.
    static func removeAll(machine: UUID) {
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: WalletScope.service(machine),
                                    kSecUseDataProtectionKeychain: true] as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { HengeLog.log("wallet", "remove all: \(status)") }
    }

    private var accessControl: SecAccessControl? {
        #if targetEnvironment(simulator)
        return nil // the simulator skips Face ID (SessionAuth)
        #else
        return SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                               SessionGate.faceIDOnly ? .biometryCurrentSet : .userPresence, nil)
        #endif
    }

    /// The session's context. The simulator has none (SessionAuth).
    private func authContext() -> (locked: Bool, context: LAContext?) {
        lock.lock()
        defer { lock.unlock() }
        #if targetEnvironment(simulator)
        return (!unlocked, nil)
        #else
        // Unlocked with no context: HENGE_AUTOPILOT_WALLET. A secret then reads as locked: it needs Face ID.
        return (!unlocked, context ?? Self.quietContext())
        #endif
    }

    /// Never shows a prompt: a call that needs Face ID fails instead.
    private static func quietContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
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
            switch status {
            case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: return Int32(HV_SECRET_LOCKED)
            default: return Int32(HV_SECRET_FAILED)
            }
        }
    }

    fileprivate func list(_ scope: String, _ each: (String, Data) -> Void) -> Int32 {
        var q = base(scope)
        q[kSecMatchLimit] = kSecMatchLimitAll
        q[kSecReturnAttributes] = true
        q[kSecUseAuthenticationContext] = Self.quietContext() // metadata needs no check
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
        let auth = authContext()
        guard !auth.locked else { return (Int32(HV_SECRET_LOCKED), nil) }
        var q = base(scope, id)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        if let context = auth.context { q[kSecUseAuthenticationContext] = context }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        return (Self.code(status, "read"), result as? Data)
    }

    /// Add and delete need no Face ID; an update does, and the session's context does not satisfy it. So: replace.
    fileprivate func write(_ scope: String, _ id: String, meta: Data, secret: Data) -> Int32 {
        guard !authContext().locked else { return Int32(HV_SECRET_LOCKED) }
        var add = base(scope, id)
        add[kSecAttrGeneric] = meta
        add[kSecValueData] = secret
        if let access = accessControl { add[kSecAttrAccessControl] = access } else { add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemDelete(base(scope, id) as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound { status = SecItemAdd(add as CFDictionary, nil) }
        }
        return Self.code(status, "write")
    }

    fileprivate func remove(_ scope: String, _ id: String) -> Int32 {
        guard !authContext().locked else { return Int32(HV_SECRET_LOCKED) }
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
