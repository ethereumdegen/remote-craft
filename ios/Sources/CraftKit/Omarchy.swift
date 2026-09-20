import Foundation

/// The literal strings Omarchy itself uses, in one place.
///
/// Every one of these is a command a person can type on the box, not a description of a
/// command. That is the rule the whole enrollment flow is built on: the app knows exactly
/// what has to happen on the other machine, so it should hand over the line rather than
/// explain it and hope.
///
/// The facts behind them, from `omacom/omarchy` (v4.0.4) rather than from memory:
///
/// - A stock Omarchy install has **sshd off and port 22 closed** — `ufw default deny
///   incoming` with only LocalSend's 53317 open. Nothing connects until someone turns SSH
///   on, and that is the first thing this app has to survive.
/// - `bin/omarchy-setup-security-sshd` is the *only* remote-in feature. It installs
///   openssh, `systemctl enable --now sshd`, `ufw limit 22/tcp`, authorizes a key, and
///   then writes `PasswordAuthentication no` into
///   `/etc/ssh/sshd_config.d/10-omarchy-hardening.conf`. Password auth is dead after
///   enrollment, which is why this app never offers a password field.
/// - Its one non-interactive flag in every *released* Omarchy is `--key=`. `--gh-keys`
///   — the "git keys" route, which fetches `https://github.com/<user>.keys` and appends
///   each line — landed upstream on 2026-08-16 and is still unreleased: v4.0.4 rejects
///   it with `unknown option` and exit 2. `githubCommand` emits both forms for that
///   reason.
/// - Omarchy never generates a keypair. `install/user/git.sh` sets `user.name` and
///   `user.email` and stops there, so "use my GitHub keys" means a key that already
///   exists on some other machine — which is exactly why that branch has to end in an
///   import, and why the Enclave key is offered first.
enum Omarchy {
    /// Omarchy's SSHD setup opens exactly one port, and it is never configurable.
    static let port = 22

    /// The script the box already has. Not a path — it is on `PATH` for the Omarchy user.
    static let setup = "omarchy-setup-security-sshd"

    /// How to get a terminal on an Omarchy box. Hyprland, default keybind.
    static let terminalKeybind = "Super + Return"

    /// The same enrollment, done by clicking. Worth showing small: it is slower and more
    /// error-prone than the command, but it is the path a user can find without this app.
    static let menuPath = "Super + Space → Setup → Security → SSHD"

    /// Where Tailscale is installed from, for a box that has no route off the LAN.
    static let tailscaleMenuPath = "Super + Space → Install → Service → Tailscale"

    static let tailscaleAddress = "tailscale ip -4"
    static let tailscaleStatus = "tailscale status --json"
    static let hostnameCommand = "hostname"

    /// Verify a pinned host key against the box itself. ed25519 because Arch's
    /// `ssh-keygen -A` always makes one and it is the key this app prefers.
    static let hostKeyCheck = "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"

    /// Put the stock host keys back when someone has deleted all but the RSA one.
    static let regenerateHostKeys = "sudo ssh-keygen -A && sudo systemctl restart sshd"

    /// Where a person adds a public key to their own GitHub account by hand.
    ///
    /// The whole point of offering this next to the device flow: pasting a key here
    /// costs the app no access to the account at all. `POST /user/keys` needs a token
    /// with write access to every SSH key you own, which is a large grant for a
    /// one-time copy the user can perform themselves in Safari, on the same phone, from
    /// the clipboard. The form's type defaults to *Authentication*, which is the only
    /// type that appears at `github.com/<user>.keys` and therefore the only type
    /// Omarchy's fetch can see.
    static let githubNewKeyURL = URL(string: "https://github.com/settings/ssh/new")!

    /// The URL Omarchy itself reads, so the user can confirm the key is actually there
    /// before walking to the box. A key pasted as a *signing* key is absent from this
    /// page while looking present in the account's settings, and that is the one
    /// failure this route can still produce.
    static func githubKeysURL(username: String) -> URL? {
        let user = githubUsername(username)
        guard !user.isEmpty else { return nil }
        return URL(string: "https://github.com/\(user).keys")
    }

    /// List the fingerprints the box currently trusts, to compare with this phone's.
    static let listAuthorizedKeys = "ssh-keygen -lf ~/.ssh/authorized_keys"

    /// Printed by `authorizeCommand` when the key is present in `authorized_keys`
    /// *after* the append. A sentinel rather than an exit status because an SSH exec
    /// channel's status is the easiest thing in this stack to lose: Citadel surfaces a
    /// non-zero exit as a thrown error, a zero exit as nothing at all, and "nothing at
    /// all" is indistinguishable from a command that never ran.
    static let authorized = "remote-craft-authorized"

    /// Authorize one more key on a box this phone can **already** reach, over the
    /// connection it already has.
    ///
    /// This is the second-device answer, and it is the one `--gh-keys` cannot give:
    /// Omarchy's script `curl`s `github.com/<user>.keys` exactly once, at the moment it
    /// runs, so a key published afterwards is invisible to a box that already ran it.
    /// Once *any* key works, though, the app has a shell — and appending a line to
    /// `authorized_keys` needs no script, no sudo, and no walk to the machine.
    ///
    /// Idempotent by `grep -qxF`: enrolling twice is a thing users do when the first
    /// attempt's result was ambiguous, and a duplicated line is how `authorized_keys`
    /// grows a key nobody can account for. `-x` anchors the whole line and `-F` turns
    /// off patterns, so the base64 in a key cannot be read as a regex.
    ///
    /// The permissions are set every time rather than only at creation. sshd silently
    /// ignores an `authorized_keys` that is group-writable — `StrictModes` is on by
    /// default — and a box whose `~/.ssh` was made by hand with a loose umask fails
    /// exactly this way, with the key visibly present in the file and refused anyway.
    static func authorizeCommand(publicLine: String) -> String {
        let line = shellLiteral(publicLine)
        guard !line.isEmpty else { return "" }
        return [
            "install -d -m 700 ~/.ssh",
            "touch ~/.ssh/authorized_keys",
            "chmod 600 ~/.ssh/authorized_keys",
            "grep -qxF '\(line)' ~/.ssh/authorized_keys || printf '%s\\n' '\(line)' >> ~/.ssh/authorized_keys",
            "grep -qxF '\(line)' ~/.ssh/authorized_keys && echo \(authorized)",
        ].joined(separator: "; ")
    }

    /// An `authorized_keys` line reduced to what is safe inside a single-quoted shell
    /// word, which is everything except the single quote itself.
    ///
    /// Stripping rather than escaping, and for the same reason `githubUsername` filters:
    /// the only characters a real key line contains are base64 and the comment, the
    /// comment is the one part a user can type, and a key whose comment had to be
    /// escaped to be safe is a key worth refusing to be clever about. Backslash goes
    /// too — it is inert inside single quotes, but this string is also shown on screen
    /// next to the `--key=` form, which is double-quoted and where it is not.
    static func shellLiteral(_ publicLine: String) -> String {
        let unsafe: Set<Character> = ["'", "\"", "\\", "`", "$", "\n", "\r"]
        // Trimmed *after* filtering, not before. Removing a trailing quote exposes the
        // space in front of it, and the result is written into `authorized_keys` and
        // then matched against with `grep -qxF`, which anchors the whole line: a line
        // stored with a trailing space is a line the app can only find again by
        // reproducing that space exactly.
        return publicLine
            .filter { !unsafe.contains($0) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `omarchy-setup-security-sshd --key="<line>"` — turns on sshd, opens the firewall
    /// and authorizes this one key, in one command.
    ///
    /// Double quotes because an `authorized_keys` line has spaces in it and because that
    /// is the form Omarchy's own `--key=` flag documents. The line is stripped of the
    /// four characters that mean something inside double quotes first: an Enclave key's
    /// comment is built from alphanumerics and hyphens and can never contain them, but
    /// an *imported* key's comment is the name the user typed into a text field, and a
    /// name containing `"` would end the quote and hand the rest of the line to a
    /// root-capable shell on someone else's machine.
    static func enrollCommand(publicLine: String) -> String {
        let unsafe: Set<Character> = ["\"", "\\", "`", "$"]
        let line = publicLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !unsafe.contains($0) }
        guard !line.isEmpty else { return setup }
        return "\(setup) --key=\"\(line)\""
    }

    /// `omarchy-setup-security-sshd --gh-keys <user> || omarchy-setup-security-sshd` —
    /// the box command.
    ///
    /// The whole reason the app signs in to GitHub: this line is short enough to read
    /// off a phone and type at the box's keyboard, where `--key="ecdsa-sha2-nistp256
    /// AAAA…"` is a hundred characters of base64 that needs a QR code and a camera to
    /// cross the gap between the two machines.
    ///
    /// The `|| ` half is not decoration. `--gh-keys` exists only on Omarchy's master
    /// branch (merged 2026-08-16, after the v4.0.4 tag), and a released box parses its
    /// arguments *before* it touches anything: an unknown flag prints `unknown option`
    /// and exits 2 having installed nothing, opened no port and authorized no key. The
    /// fallback then runs the same script with no arguments, which asks the one
    /// question the flag was answering — "Grab key from GitHub", then the username.
    /// Same outcome, same two machines, one line that works on both.
    ///
    /// What it does not do is subscribe. Omarchy's script `curl`s
    /// `github.com/<user>.keys` exactly once, when it runs, so a key published
    /// afterwards is invisible to a box that already ran it — which is why
    /// `RemoteEnroll` exists for every device after the first.
    static func githubCommand(username: String) -> String {
        let user = githubUsername(username)
        // No username is not a shorter command, it is a different one: `--gh-keys` with
        // nothing after it is an error on master and an unknown flag everywhere else.
        guard !user.isEmpty else { return setup }
        return "\(setup) --gh-keys \(user) || \(setup)"
    }

    /// GitHub usernames are alphanumerics and hyphens, nothing else. Filtering rather
    /// than quoting because the result is pasted into a root-capable shell command: a
    /// field that can carry a `;` is a field that can carry a second command. The name
    /// now comes from the signed-in account rather than a text field, which makes this
    /// belt and braces — and worth keeping for exactly that reason, since the thing
    /// that would remove the braces is a refactor nobody will re-audit.
    static func githubUsername(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(39)
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    }

    // MARK: - liveness

    /// Omarchy's own `~/.ssh/config` defaults, applied to this client so the phone gives
    /// up at the same moment a laptop would: `ConnectTimeout 10`,
    /// `ServerAliveInterval 15`, `ServerAliveCountMax 3`.
    static let connectTimeout: Int64 = 10
    static let keepaliveInterval: CInt = 15
    static let keepaliveMisses: CInt = 3
}

