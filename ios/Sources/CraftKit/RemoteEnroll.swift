import Citadel
import Foundation
import NIOCore

/// The observable result of trying to authorize a key on a box.
///
/// Two cases, because a borrowed connection removes the third. Nothing here dials, so
/// there is no connection failure to diagnose: by the time this runs the box has already
/// answered, already accepted a key, and already given the app a shell. What is left is
/// "the box confirmed" and "it did not", and the second is a sentence rather than a named
/// cause because there is no table of ways `grep` can disagree with itself.
enum AuthorizeResult: Equatable {
    /// The box confirmed the line is in `~/.ssh/authorized_keys`, on this address.
    case authorized(address: String)
    /// The command ran, or failed to, and the box did not confirm.
    case failed(String)
}

/// Authorizing one more key over a connection the app already has.
///
/// Costs no new connection, which is the whole design. Omarchy's SSHD setup runs
/// `ufw limit 22/tcp`, and that rule bans a source address at six connections in thirty
/// seconds — so a second dialer, with its own view of that window, is how an app locks
/// itself out of the box it is enrolling. SSH multiplexes: an exec channel on the live
/// `SSHClient` behind the terminal's PTY opens no socket, touches no ufw counter, and
/// authenticates nothing a second time.
///
/// The precondition is therefore honest rather than incidental: this works only on a box
/// the phone can *already* reach. That is not a gap in the feature, it is the case
/// Omarchy's own routes cannot cover — `--gh-keys` `curl`s `github.com/<user>.keys` once,
/// when the setup script runs, so a key published afterwards is invisible to a box that
/// already ran it, and `--key=` has to be typed at a real keyboard. Once any key works,
/// appending a line to `authorized_keys` needs no script, no sudo, and nobody standing at
/// the box, which is what turns a second phone or a regenerated Enclave key into a
/// thirty-second job instead of an errand.
enum RemoteEnroll {
    /// A cap on what the exec channel will buffer before giving up.
    ///
    /// The command prints one short word. Everything else on that channel is noise from
    /// the login shell — sshd runs an exec command through the user's shell, and bash
    /// sources `~/.bashrc` even non-interactively when it is started by sshd, so a box
    /// with a `fastfetch` or a themed banner in there writes a screenful before the
    /// first `grep` runs. 64 KiB is far more than any banner and far less than a
    /// `~/.bashrc` that accidentally tails a log into this app's memory.
    private static let maxResponse = 64 * 1024

    /// What the remote command's combined output means.
    ///
    /// Whole-line, not `contains`. The sentinel shares the channel with whatever the
    /// login shell prints, and the word appears in this app's own enrollment text — a
    /// box whose `.bashrc` echoes the command it is about to run, or a shell-rc banner
    /// that quotes it, would otherwise report success for a key that never landed.
    /// `authorizeCommand` emits it with `echo`, alone on its line, so an exact match
    /// after trimming is both sufficient and the only safe test.
    ///
    /// Pure and dependency-free on purpose: the one piece of this file that decides
    /// success or failure is testable against real captured output, with no box.
    static func read(output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces) == Omarchy.authorized
        }
    }

    /// Append `line` to `~/.ssh/authorized_keys` over `client`, and report what the box
    /// said. `address` is only carried through to name where it happened.
    ///
    /// **The client is borrowed, never owned.** This function must not close it and does
    /// not: the caller's `SSHClient` is the one holding the user's live PTY, and closing
    /// it would drop the terminal — the shell, its scrollback and whatever is running in
    /// it — to enroll a key. The exec channel opened here closes itself when the command
    /// exits, which is the only thing this function is entitled to end.
    ///
    /// `@MainActor` for the same reason as `ShellSession`: the result goes straight onto
    /// a screen, the awaits inside are NIO's work on its own event loops and never block
    /// the main thread, and `ShellSession.describe` — the error-describer this reuses
    /// rather than duplicating — is isolated to it.
    ///
    /// Both refusals below happen before the channel is opened. Nothing is spent on a
    /// request that cannot succeed, and nothing unparseable is ever written into a file
    /// sshd reads.
    @MainActor
    static func authorize(line: String,
                          over client: SSHClient,
                          address: String) async -> AuthorizeResult {
        let command = Omarchy.authorizeCommand(publicLine: line)
        guard !command.isEmpty else {
            return .failed("There is no key to authorize. The line is empty once the characters a shell would interpret are removed, which is what an empty or whitespace-only public key looks like by the time it reaches here.")
        }
        // Checked against the stripped line rather than the raw one, because the
        // stripped line is what the box will store: a key whose base64 contained a
        // quote parses before `shellLiteral` and is a corrupt `authorized_keys` entry
        // after it, and sshd would go on refusing a key the app reported as enrolled.
        guard OpenSSHWire.fingerprint(ofPublicLine: Omarchy.shellLiteral(line)) != nil else {
            return .failed("That line is not an OpenSSH public key. It has to be the whole authorized_keys line — a type, a base64 blob and an optional comment — and this one no longer parses as one.")
        }

        do {
            // The four-argument overload, from Citadel's TTY.swift, chosen explicitly:
            // the two-argument one in ExecClient.swift is what an unqualified call
            // resolves to, and its handler fails the whole command with `TTYSTDError`
            // the moment anything reaches stderr — which a login shell's banner does
            // routinely. This one folds stderr into the result instead, so the banner
            // becomes noise `read(output:)` skips rather than a failure.
            //
            // `inShell: false` keeps it an RFC 4254 exec request rather than a shell
            // with the command typed into it: no prompt, no echo of the command itself,
            // and an exit status the server actually reports.
            let buffer = try await client.executeCommand(command,
                                                         maxResponseSize: maxResponse,
                                                         mergeStreams: true,
                                                         inShell: false)
            guard read(output: String(buffer: buffer)) else {
                return .failed("The box ran the command and did not confirm the key afterwards. Check ~/.ssh/authorized_keys on it with \(Omarchy.listAuthorizedKeys).")
            }
            return .authorized(address: address)
        } catch let failure as SSHClient.CommandFailed {
            // The command's last stage is `grep -qxF … && echo`, which exits 1 for
            // exactly one reason: the line was not in the file after the append. That
            // is a real answer from the box, and reporting it as `CommandFailed(1)`
            // would throw the one diagnostic fact away.
            let reason = failure.exitCode == 1
                ? "the key was not in the file after appending it"
                : "the command stopped with status \(failure.exitCode)"
            return .failed("The box did not authorize the key: \(reason). A likely cause is a home directory the account cannot write to, or a full disk.")
        } catch {
            // Everything else belongs to the transport: a channel the box would not
            // open, a connection that died between the PTY and this command, an
            // oversized response. `ShellSession.describe` already frames those, and a
            // second describer here would drift from it.
            return .failed(ShellSession.describe(error))
        }
    }
}
