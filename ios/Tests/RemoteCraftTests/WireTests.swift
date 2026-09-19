import CryptoKit
import XCTest

@testable import RemoteCraft

/// The `authorized_keys` line this app prints must be byte-identical to the one
/// `ssh-keygen` would print for the same key, or sshd silently never offers publickey auth
/// and the app looks broken for a reason nothing logs.
///
/// The vectors below were produced by `ssh-keygen -t ed25519` and `ssh-keygen -t ecdsa`.
/// Only the *raw public key bytes* are shared with the encoder — the expected base64 is
/// ssh-keygen's own output — so this compares two independent encodings of the same key
/// rather than the code against itself.
final class OpenSSHWireTests: XCTestCase {
    func testEd25519LineMatchesSSHKeygen() throws {
        let raw = Data(base64Encoded: "q+YVvbK3vps8eheP5gLx3XZd9dH1vHeZA/rVE3za9ys=")!
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: raw)

        XCTAssertEqual(
            OpenSSHWire.line(for: key, comment: "vector"),
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKvmFb2yt76bPHoXj+YC8d12XfXR9bx3mQP61RN82vcr vector")
    }

    func testP256LineMatchesSSHKeygen() throws {
        let q = Data(base64Encoded: "BGFSO8jsBtB5yb9TBe2PxsPPAusNWecJZrp+E9rth6qVu3/KLxOMEIOUUmcsTynO69LEupudKPWRJLpPgq88xCY=")!
        let key = try P256.Signing.PublicKey(x963Representation: q)

        XCTAssertEqual(
            OpenSSHWire.line(for: key, comment: "vector"),
            "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGFSO8jsBtB5yb9TBe2PxsPPAusNWecJZrp+E9rth6qVu3/KLxOMEIOUUmcsTynO69LEupudKPWRJLpPgq88xCY= vector")
    }

    /// A key with no comment is still a valid line — no trailing space, which some
    /// `authorized_keys` parsers treat as an empty option field.
    func testLineWithoutCommentHasNoTrailingSpace() throws {
        let raw = Data(base64Encoded: "q+YVvbK3vps8eheP5gLx3XZd9dH1vHeZA/rVE3za9ys=")!
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: raw)

        XCTAssertFalse(OpenSSHWire.line(for: key, comment: "").hasSuffix(" "))
    }
}

final class HostCandidateTests: XCTestCase {
    /// The name first — it is what the user's ACLs and known_hosts are written in terms
    /// of — and the pinned address second, which is the entire point of having one.
    func testNameIsTriedBeforeFallback() {
        let host = SSHHost(name: "box", address: "box.tail1.ts.net",
                           fallbackAddress: "100.64.0.9", port: 22, username: "andrew")

        XCTAssertEqual(host.candidates(), ["box.tail1.ts.net", "100.64.0.9"])
    }

    /// A host whose fallback duplicates its address must not be dialled twice: the second
    /// attempt doubles the time to fail with nothing new to learn.
    func testDuplicateAndBlankAddressesCollapse() {
        let host = SSHHost(address: "100.64.0.9", fallbackAddress: "  100.64.0.9 ",
                           username: "andrew")

        XCTAssertEqual(host.candidates(), ["100.64.0.9"])
    }

    func testHostWithoutAddressOrUserIsRefused() {
        XCTAssertFalse(SSHHost(address: "", fallbackAddress: "", username: "andrew").isUsable)
        XCTAssertFalse(SSHHost(address: "box", fallbackAddress: "", username: " ").isUsable)
        XCTAssertTrue(SSHHost(address: "box", username: "andrew").isUsable)
    }

    /// The agent is reached over the same two addresses, in the same order, on its own
    /// port — the fallback problem does not stop being a problem because the protocol
    /// changed from SSH to HTTP.
    func testAgentBasesFollowTheSameOrder() {
        let host = SSHHost(address: "box.ts.net", fallbackAddress: "100.64.0.9",
                           username: "andrew", agentPort: 3002)

        XCTAssertEqual(host.agentBases().map(\.absoluteString),
                       ["http://box.ts.net:3002/api/v1", "http://100.64.0.9:3002/api/v1"])
    }
}
