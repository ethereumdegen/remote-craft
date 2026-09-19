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
/// - Its two non-interactive flags are `--key=` and `--gh-keys`. The second is the "git
///   keys" route: Omarchy fetches `https://github.com/<user>.keys` and appends each line.
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

    /// List the fingerprints the box currently trusts, to compare with this phone's.
    static let listAuthorizedKeys = "ssh-keygen -lf ~/.ssh/authorized_keys"

    /// A GitHub *signing* key is not published at `/<user>.keys`; only an *authentication*
    /// key is. That single word is the difference between `--gh-keys` working and
    /// silently authorizing nothing.
    static let publishAuthenticationKey =
        #"gh ssh-key add ~/.ssh/id_ed25519.pub --type authentication --title "iPhone""#

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

    /// `omarchy-setup-security-sshd --gh-keys <user>` — the "git keys" route.
    static func githubCommand(username: String) -> String {
        let user = githubUsername(username)
        guard !user.isEmpty else { return "\(setup) --gh-keys" }
        return "\(setup) --gh-keys \(user)"
    }

    /// GitHub usernames are alphanumerics and hyphens, nothing else. Filtering rather
    /// than quoting because the result is pasted into a root-capable shell command: a
    /// field that can carry a `;` is a field that can carry a second command.
    static func githubUsername(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(39)
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    }

    static func githubKeysURL(username: String) -> URL? {
        let user = githubUsername(username)
        guard !user.isEmpty else { return nil }
        return URL(string: "https://github.com/\(user).keys")
    }

    // MARK: - liveness

    /// Omarchy's own `~/.ssh/config` defaults, applied to this client so the phone gives
    /// up at the same moment a laptop would: `ConnectTimeout 10`,
    /// `ServerAliveInterval 15`, `ServerAliveCountMax 3`.
    static let connectTimeout: Int64 = 10
    static let keepaliveInterval: CInt = 15
    static let keepaliveMisses: CInt = 3
}

/// What `https://github.com/<user>.keys` said.
///
/// Three outcomes that look identical if you only check for an error, and mean completely
/// different things to someone about to walk to another machine and type `--gh-keys`:
/// there is no such user, the user exists and has published nothing, or there are N keys
/// and the route will work.
enum GitHubKeys: Equatable {
    case published(Int)
    case noSuchUser(String)
    case noKeys(String)
    case failed(String)

    /// GitHub answers `/<user>.keys` with 200 and a body of one key per line, or 404 for
    /// a user that does not exist. A user with no *authentication* keys is a 200 with an
    /// empty body — the case that makes `--gh-keys` authorize nothing at all while
    /// appearing to succeed.
    static func read(status: Int, body: String, username: String) -> GitHubKeys {
        let user = Omarchy.githubUsername(username)
        switch status {
        case 404:
            return .noSuchUser(user)
        case 200:
            let lines = body
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return lines.isEmpty ? .noKeys(user) : .published(lines.count)
        default:
            return .failed("GitHub answered \(status)")
        }
    }

    /// One line, the way the enrollment screen says it.
    var summary: String {
        switch self {
        case .published(let count):
            return count == 1
                ? "1 key published — `--gh-keys` will authorize it."
                : "\(count) keys published — `--gh-keys` will authorize all \(count)."
        case .noSuchUser(let user):
            return "GitHub has no user called \(user)."
        case .noKeys(let user):
            return "\(user) exists but has published no SSH keys. `--gh-keys` would authorize nothing."
        case .failed(let why):
            return why
        }
    }

    /// Only `published` means the route works. The other three are why this button exists
    /// at all: finding out here beats finding out at the box.
    var isUsable: Bool {
        if case .published = self { return true }
        return false
    }
}
