import CryptoKit
import Foundation

/// The OpenSSH public-key wire format, written by hand.
///
/// It exists because the one key this app can generate — a Secure Enclave P-256 signing
/// key — cannot be handed to anything that would print its `authorized_keys` line for us.
/// `SecureEnclave.P256.Signing.PrivateKey` is not a `P256.Signing.PrivateKey`: the private
/// scalar never leaves the chip, so no library that wants key bytes can serialise it. What
/// it does expose is `publicKey`, and a public key is all `authorized_keys` ever needed.
///
/// The format (RFC 4253 §6.6, RFC 5656 §3.1) is a sequence of length-prefixed strings:
///
///     ecdsa-sha2-nistp256:  "ecdsa-sha2-nistp256" | "nistp256" | Q
///     ssh-ed25519:          "ssh-ed25519"         | 32 raw bytes
///
/// where `Q` is the uncompressed point, `0x04 ‖ X ‖ Y`, which is exactly CryptoKit's
/// `x963Representation`. Lengths are 32-bit big-endian. Get any of it wrong and sshd says
/// nothing at all — it simply does not offer publickey auth — so this is unit-tested
/// against a known-good vector rather than trusted.
enum OpenSSHWire {
    /// One length-prefixed field.
    static func string(_ bytes: [UInt8]) -> [UInt8] {
        let n = UInt32(bytes.count)
        return [UInt8(truncatingIfNeeded: n >> 24),
                UInt8(truncatingIfNeeded: n >> 16),
                UInt8(truncatingIfNeeded: n >> 8),
                UInt8(truncatingIfNeeded: n)] + bytes
    }

    static func string(_ text: String) -> [UInt8] { string(Array(text.utf8)) }

    /// The blob an `ecdsa-sha2-nistp256` key carries, unencoded.
    static func p256Blob(x963: Data) -> [UInt8] {
        string("ecdsa-sha2-nistp256") + string("nistp256") + string(Array(x963))
    }

    static func ed25519Blob(raw: Data) -> [UInt8] {
        string("ssh-ed25519") + string(Array(raw))
    }

    /// A complete `authorized_keys` line: `<type> <base64> <comment>`.
    static func line(type: String, blob: [UInt8], comment: String) -> String {
        let encoded = Data(blob).base64EncodedString()
        return comment.isEmpty ? "\(type) \(encoded)" : "\(type) \(encoded) \(comment)"
    }

    static func line(for key: P256.Signing.PublicKey, comment: String) -> String {
        line(type: "ecdsa-sha2-nistp256",
             blob: p256Blob(x963: key.x963Representation),
             comment: comment)
    }

    /// `SHA256:…`, the fingerprint `ssh-keygen -l` prints for the same key.
    ///
    /// It exists so the app can show the user something they can compare with what the
    /// box says, rather than a 400-character base64 blob nobody will diff by eye. The
    /// format is OpenSSH's: SHA-256 over the raw key blob — the middle field of the line,
    /// base64-decoded — re-encoded as base64 with the padding stripped.
    ///
    /// `nil` when the line has no decodable blob, which is the honest answer for an RSA
    /// key imported without its `.pub` file.
    static func fingerprint(ofPublicLine line: String) -> String? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
            return nil
        }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    static func line(for key: Curve25519.Signing.PublicKey, comment: String) -> String {
        line(type: "ssh-ed25519",
             blob: ed25519Blob(raw: key.rawRepresentation),
             comment: comment)
    }
}
