import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH

/// A key this app can authenticate with, as the app remembers it.
///
/// Nothing secret is in here — this is the `UserDefaults` half. The material sits in the
/// Keychain under `Secret.enclaveKey(id)` or `Secret.importedKey(id)`, and the two halves
/// are joined by `id` alone.
struct KeyRecord: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        /// Generated on this device, private half inside the Secure Enclave.
        case enclave
        /// Pasted in by the user; the app holds the actual private key.
        case imported
    }

    var id: String = UUID().uuidString
    var name: String = ""
    var kind: Kind = .enclave
    /// The `authorized_keys` line, when the app can compute one.
    ///
    /// Always present for an enclave key. For an imported key it is present when the key
    /// is ed25519 — the public half is derivable from the private one — and empty for RSA,
    /// where deriving it would mean re-implementing the modulus encoding for a line the
    /// user already has on disk next to the key they pasted.
    var publicLine: String = ""
    var algorithm: String = ""
    var created: Date = Date()

    var isEnclave: Bool { kind == .enclave }
}

enum KeyError: LocalizedError {
    case enclaveUnavailable
    case enclaveFailed(String)
    case missingMaterial(String)
    case unsupportedKeyType(String)
    case unreadableKey(String)

    var errorDescription: String? {
        switch self {
        case .enclaveUnavailable:
            return "This device has no Secure Enclave. Import an existing key instead."
        case .enclaveFailed(let why):
            return "The Secure Enclave refused to make a key: \(why)."
        case .missingMaterial(let name):
            return "The private key for \(name) is not in the Keychain any more. Re-import or regenerate it."
        case .unsupportedKeyType(let type):
            return "\(type) keys are not supported. Enroll an ed25519 or RSA key, or generate one on this device."
        case .unreadableKey(let why):
            return "That is not a key this app can read: \(why). Paste the whole OpenSSH private key, BEGIN and END lines included."
        }
    }
}

/// Makes keys, reads keys, and turns a key into something Citadel will authenticate with.
///
/// The two paths are genuinely different and neither can do the other's job:
///
/// - **Secure Enclave.** `SecureEnclave.P256.Signing.PrivateKey` is a handle, not a key:
///   the scalar is generated inside the chip and never comes out, so it cannot be backed
///   up, exported, or moved to another phone — and it cannot be *imported* either. That
///   last point is the one that surprises people: an existing ed25519 key can never live
///   in the Enclave, because the Enclave only ever does NIST P-256 and only ever over keys
///   it generated itself. What persists is `dataRepresentation`, an encrypted blob only
///   this chip can re-open.
/// - **Imported.** An OpenSSH private key the user pastes. Citadel parses ed25519 and RSA;
///   the app holds the real bytes, which is strictly weaker and is why the Enclave path is
///   offered first.
enum KeyVault {
    /// Generate an Enclave key and persist its handle. Returns the record to store.
    static func generateEnclaveKey(named name: String, deviceName: String) throws -> KeyRecord {
        guard SecureEnclave.isAvailable else { throw KeyError.enclaveUnavailable }

        var accessError: Unmanaged<CFError>?
        // `.privateKeyUsage` alone: signing must work whenever the phone is unlocked, with
        // no biometric prompt. Adding `.userPresence` would put a Face ID sheet in front of
        // every SSH handshake, including the silent reconnect after the app wakes — which
        // is exactly when the user is not looking at the screen.
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            &accessError)
        else {
            let why = (accessError?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw KeyError.enclaveFailed(why)
        }

        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        } catch {
            throw KeyError.enclaveFailed(error.localizedDescription)
        }

        let id = UUID().uuidString
        let status = Keychain.save(key.dataRepresentation, as: Secret.enclaveKey(id))
        guard status == errSecSuccess else {
            throw KeyError.enclaveFailed("the Keychain returned OSStatus \(status)")
        }

        return KeyRecord(
            id: id,
            name: name,
            kind: .enclave,
            publicLine: OpenSSHWire.line(for: key.publicKey, comment: "remote-craft@\(deviceName)"),
            algorithm: "ecdsa-sha2-nistp256")
    }

    /// Store a pasted OpenSSH private key, after proving the app can actually parse it.
    ///
    /// Parsing now rather than at connect time is the difference between "that key is
    /// encrypted, give me the passphrase" on the screen where the user is pasting, and a
    /// failed SSH handshake three screens later.
    static func importKey(named name: String, pem: String, passphrase: String) throws -> KeyRecord {
        let text = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        let type: SSHKeyType
        do {
            type = try SSHKeyDetection.detectPrivateKeyType(from: text)
        } catch {
            throw KeyError.unreadableKey(error.localizedDescription)
        }

        let secret = passphrase.isEmpty ? nil : Data(passphrase.utf8)
        var publicLine = ""
        switch type {
        case .ed25519:
            let key: Curve25519.Signing.PrivateKey
            do {
                key = try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: secret)
            } catch {
                throw KeyError.unreadableKey(error.localizedDescription)
            }
            publicLine = OpenSSHWire.line(for: key.publicKey, comment: name)
        case .rsa:
            do {
                _ = try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: secret)
            } catch {
                throw KeyError.unreadableKey(error.localizedDescription)
            }
        default:
            throw KeyError.unsupportedKeyType(type.description)
        }

        let id = UUID().uuidString
        let saved = Keychain.save(text, as: Secret.importedKey(id))
        guard saved == errSecSuccess else {
            throw KeyError.unreadableKey("the Keychain returned OSStatus \(saved)")
        }
        if !passphrase.isEmpty {
            Keychain.save(passphrase, as: Secret.keyPassphrase(id))
        }

        return KeyRecord(id: id, name: name, kind: .imported,
                         publicLine: publicLine, algorithm: type.rawValue)
    }

    static func forget(_ record: KeyRecord) {
        Keychain.delete(Secret.enclaveKey(record.id))
        Keychain.delete(Secret.importedKey(record.id))
        Keychain.delete(Secret.keyPassphrase(record.id))
    }

    /// Turn a stored key into the thing Citadel authenticates with.
    static func authentication(for record: KeyRecord, username: String) throws -> SSHAuthenticationMethod {
        switch record.kind {
        case .enclave:
            guard let blob = Keychain.loadData(Secret.enclaveKey(record.id)) else {
                throw KeyError.missingMaterial(record.name)
            }
            let key: SecureEnclave.P256.Signing.PrivateKey
            do {
                key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
            } catch {
                throw KeyError.enclaveFailed(error.localizedDescription)
            }
            // Citadel's `.p256(username:privateKey:)` wants a `P256.Signing.PrivateKey`,
            // and an Enclave key is not one and cannot be converted into one. `.custom`
            // with our own delegate is the only door: NIOSSH knows how to sign with an
            // Enclave handle, Citadel's convenience constructors simply never offer it one.
            return .custom(EnclaveAuthentication(username: username, key: key))

        case .imported:
            guard let text = Keychain.load(Secret.importedKey(record.id)) else {
                throw KeyError.missingMaterial(record.name)
            }
            let stored = Keychain.load(Secret.keyPassphrase(record.id))
            let secret = stored.map { Data($0.utf8) }
            let type = (try? SSHKeyDetection.detectPrivateKeyType(from: text)) ?? .ed25519
            switch type {
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: secret)
                return .rsa(username: username, privateKey: key)
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: secret)
                return .ed25519(username: username, privateKey: key)
            default:
                throw KeyError.unsupportedKeyType(type.description)
            }
        }
    }
}

/// Offers a Secure Enclave key, once.
///
/// "Once" matters: `nextAuthenticationType` is called again after every refusal, and a
/// delegate that keeps offering the same key turns one rejected key into an endless
/// handshake. Succeeding with `nil` is how NIOSSH is told there is nothing left to try,
/// which surfaces as a clean authentication failure instead of a hang.
final class EnclaveAuthentication: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let key: SecureEnclave.P256.Signing.PrivateKey
    private var offered = false

    init(username: String, key: SecureEnclave.P256.Signing.PrivateKey) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: key)))))
    }
}
