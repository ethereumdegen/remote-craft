import Foundation
import Security

/// Everything secret this app holds, keyed by a stable account string.
///
/// Three kinds live here and the distinction matters. A **host key** is an OpenSSH private
/// key the user pasted in; the app can read its bytes and hand them to the SSH client. An
/// **enclave key** is the opaque `dataRepresentation` of a `SecureEnclave.P256.Signing`
/// key — not a private key at all, but a wrapped reference the Secure Enclave will re-open
/// for this app on this device and nothing else. An **agent token** is the bearer for a
/// metalcraft-agent's workshop API.
///
/// None of them belongs in `UserDefaults`: the first two are credentials that reach a
/// shell, and the third reaches an agent that has one.
enum Secret {
    /// The pasted OpenSSH private key for key id `id`.
    static func importedKey(_ id: String) -> String { "key.imported.\(id)" }
    /// `SecureEnclave.P256.Signing.PrivateKey.dataRepresentation`, base64, for key id `id`.
    static func enclaveKey(_ id: String) -> String { "key.enclave.\(id)" }
    /// The passphrase for an imported key, if it has one.
    static func keyPassphrase(_ id: String) -> String { "key.passphrase.\(id)" }
    /// The pinned host key for one address, as an OpenSSH public line.
    ///
    /// A host key is not itself a secret — but the *pin* is a security decision, and a
    /// decision a wiped preference file can silently revert is not a decision at all.
    /// Here it outlives `UserDefaults`, so a box whose key changed stays refused.
    static func hostKey(address: String, port: Int) -> String { "hostkey.\(address):\(port)" }
    /// The workshop API bearer for agent id `id`.
    static func agentToken(_ id: String) -> String { "agent.token.\(id)" }
}

enum Keychain {
    private static let service = "com.remotecraft.ios"

    /// Write, and **say whether it worked**.
    ///
    /// The status is returned rather than discarded because the alternative is a key that
    /// appears to be saved for a whole session and is gone on the next launch with nothing
    /// anywhere saying why. The commonest cause is an unsigned build
    /// (`CODE_SIGNING_ALLOWED=NO`), which has no keychain entitlement at all and fails
    /// every write with `errSecMissingEntitlement`.
    @discardableResult
    static func save(_ value: String, as account: String) -> OSStatus {
        save(Data(value.utf8), as: account)
    }

    @discardableResult
    static func save(_ value: Data, as account: String) -> OSStatus {
        var query = base(account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = value
        // ThisDeviceOnly: none of this should ride an iCloud backup to another phone. An
        // enclave reference is meaningless there anyway, and a private key that reaches a
        // shell should not be restorable onto hardware the user no longer holds.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    static func loadData(_ account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data
        else { return nil }
        return data
    }

    static func load(_ account: String) -> String? {
        guard let data = loadData(account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    /// Every account this app holds whose name starts with `prefix`, sorted.
    ///
    /// Only ever used to *list* pinned host keys in Settings. It returns names, never
    /// values, so the enumeration cannot become a way to spill key material into a view.
    static func accounts(prefix: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]]
        else { return [] }
        return items
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
            .sorted()
    }

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
