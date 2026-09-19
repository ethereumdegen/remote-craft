import Foundation
import Observation
import UIKit

/// The keys this phone can authenticate with.
///
/// Records in `UserDefaults` under `rc.keys`, material in the Keychain. Deleting a record
/// deletes the material with it: a key handle whose Enclave key is gone is worse than no
/// key, because it looks selectable and fails at connect time.
@MainActor
@Observable
final class KeyRing {
    static let key = "rc.keys"

    private(set) var keys: [KeyRecord] = []
    /// The last thing that went wrong, shown inline. Cleared by the next attempt.
    var failure: String?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([KeyRecord].self, from: data) {
            keys = stored
        }
    }

    func keyed(_ id: String) -> KeyRecord? { keys.first { $0.id == id } }

    @discardableResult
    func generateEnclaveKey(named name: String) -> KeyRecord? {
        failure = nil
        let label = name.trimmingCharacters(in: .whitespaces).isEmpty ? "iPhone key" : name
        do {
            let record = try KeyVault.generateEnclaveKey(
                named: label,
                deviceName: Self.deviceSlug())
            keys.append(record)
            flush()
            return record
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func importKey(named name: String, pem: String, passphrase: String) -> KeyRecord? {
        failure = nil
        let label = name.trimmingCharacters(in: .whitespaces).isEmpty ? "imported key" : name
        do {
            let record = try KeyVault.importKey(named: label, pem: pem, passphrase: passphrase)
            keys.append(record)
            flush()
            return record
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    func delete(_ record: KeyRecord) {
        KeyVault.forget(record)
        keys.removeAll { $0.id == record.id }
        flush()
    }

    /// The comment on the generated public line. `UIDevice.name` is "Andrew's iPhone" —
    /// spaces and an apostrophe, both of which would split the comment field of an
    /// `authorized_keys` line into nonsense.
    private static func deviceSlug() -> String {
        let name = UIDevice.current.name
        let cleaned = name.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let slug = String(cleaned).lowercased()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return slug.isEmpty ? "iphone" : slug
    }

    private func flush() {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
