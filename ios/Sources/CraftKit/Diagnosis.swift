import Foundation

/// What kind of name an address is.
///
/// The same failure means different things depending on who was supposed to answer the
/// lookup: a name that does not resolve is Tailscale's problem when it is a MagicDNS
/// name, avahi's when it ends in `.local`, and impossible when it is a `100.x` literal.
enum AddressKind: Equatable {
    /// A tailnet name — `omarchy` or `omarchy.tail1234.ts.net`. MagicDNS answers it.
    case magicDNS
    /// A `100.x` tailnet address, which cannot fail to resolve because it is not a name.
    case tailnetIP
    /// `<hostname>.local`, answered by avahi over the LAN. Omarchy enables avahi and
    /// defaults its hostname to `omarchy`, so `omarchy.local` works out of the box —
    /// on the same Wi-Fi, and nowhere else.
    case bonjour
    /// A literal address that is not a tailnet one, or anything else the user typed.
    case other

    static func of(_ address: String) -> AddressKind {
        let text = address.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasSuffix(".local") { return .bonjour }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let isIPv4 = parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) < 256
        }
        if isIPv4 { return parts[0] == "100" ? .tailnetIP : .other }
        if text.contains(":") { return .other }
        return .magicDNS
    }
}

/// The one observable thing a dial attempt produced.
///
/// Deliberately coarse and deliberately closed: these are the outcomes this app can tell
/// apart from where it stands, and every one of them maps to a different sentence. The
/// classifier works on the *text* of an error rather than its type because the errors
/// arrive from three libraries (Citadel, NIOSSH, NIOPosix), two of which express the
/// interesting distinctions only in a description string — and because a pure
/// `String -> DialOutcome` function can be tested against the real strings without a box.
enum DialOutcome: Equatable {
    /// DNS said nothing. The socket was never opened.
    case nameNotResolved
    /// TCP RST: the box is up and nothing is listening on the port.
    case connectionRefused
    /// No answer at all before the timeout: dropped packets, a firewall that DROPs
    /// rather than rejects, or a machine that is asleep.
    case timedOut
    /// sshd offered publickey and rejected the one this phone has.
    case publicKeyRejected
    /// sshd did not offer publickey at all — password or keyboard-interactive only.
    case noPublicKeyMethod
    /// The host key is not the one pinned for this address.
    case hostKeyRejected
    /// Key exchange found no host-key algorithm in common.
    case hostKeyAlgorithm
    case other(String)

    /// Map an error's description onto an outcome.
    ///
    /// Order matters twice over.
    ///
    /// The SSH-level markers come first: an authentication failure also mentions the
    /// host, and a host-key rejection surfaces as a connection failure one layer down.
    ///
    /// Then the *refusal and timeout* markers come before the DNS one, which is the
    /// opposite of the obvious order and the correct one. A `NIOConnectionError`
    /// description carries `dnsAError`, `dnsAAAAError` **and** `connectionErrors` in the
    /// same string, so a host whose A record is missing while its AAAA resolves and then
    /// refuses produces both markers at once. A `connectionErrors` entry can only exist
    /// if resolution produced an address to connect to, so it is strictly the more
    /// specific fact — and reporting a refusing or sleeping box as "MagicDNS did not
    /// answer" sends the user to debug a resolver that is working.
    static func classify(_ text: String) -> DialOutcome {
        if text.contains("hostKeyChanged") {
            return .hostKeyRejected
        }
        if text.contains("keyExchangeNegotiationFailure")
            || text.contains("invalidHostKeyForKeyExchange")
            || text.contains("unknownPublicKey") {
            return .hostKeyAlgorithm
        }
        if text.contains("unsupportedPrivateKeyAuthentication")
            || text.contains("unsupportedPasswordAuthentication") {
            return .noPublicKeyMethod
        }
        if text.contains("allAuthenticationOptionsFailed")
            || text.contains("AuthenticationFailed")
            || text.contains("authenticationFailed")
            || text.contains("invalidUserAuthSignature") {
            return .publicKeyRejected
        }
        if text.contains("Connection refused") || text.contains("ECONNREFUSED") {
            return .connectionRefused
        }
        // "No route to host" is grouped with the timeouts on purpose: from the phone's
        // side both mean *nothing answered*, and the diagnoses below split that by what
        // else is known about the address rather than by which errno arrived.
        //
        // `Connect timeout` — capitalised, with the duration in brackets — is what
        // `ChannelError`'s own `description` produces, and it is what a sleeping Omarchy
        // box actually delivers here. `connectTimeout` is the reflected spelling the
        // same case has wherever the error is printed without its `CustomStringConvertible`.
        if text.contains("Connect timeout")
            || text.contains("connectTimeout")
            || text.contains("ETIMEDOUT")
            || text.contains("timed out")
            || text.contains("No route to host")
            || text.contains("EHOSTUNREACH")
            || text.contains("Network is unreachable") {
            return .timedOut
        }
        // What a failed lookup becomes inside `NIOConnectionError`: the wrapper prefixes
        // `DNS error:` and the payload is a `SocketAddressError.UnknownHost` carrying
        // getaddrinfo's own wording — which on Darwin, and therefore on the simulator
        // and the phone, is "nodename nor servname provided". `unknown(host:` is the
        // deprecated case the same failure used to arrive as.
        if text.contains("DNS error:")
            || text.contains("SocketAddressError.UnknownHost")
            || text.contains("unknown(host:")
            || text.contains("nodeNameNotFound")
            || text.contains("nodename nor servname provided")
            || text.contains("Name or service not known") {
            return .nameNotResolved
        }
        return .other(text)
    }
}

/// Everything the app knows about one failed connection, and nothing it does not.
///
/// A plain value with no behaviour so the mapping below can be exercised exhaustively in
/// a unit test — which is the point: the error table is the part of this app a user meets
/// on their worst day, and it should not be reachable only by breaking a real box.
struct ConnectionFacts: Equatable {
    var address: String = ""
    /// The account the key was offered for. sshd answers "no such user" and "that key is
    /// not in this user's authorized_keys" with the same refusal, so the username is part
    /// of what a rejection means.
    var username: String = ""
    var outcome: DialOutcome = .other("")
    /// A host key is already pinned for this address: the box has answered this phone
    /// before, so silence now means it stopped answering rather than never started.
    var everConnected: Bool = false
    /// TCP connections this phone has opened to the box in the last 30 seconds, this one
    /// included — the number ufw's `limit` rule counts.
    var connectionsInWindow: Int = 1
    /// This phone's `authorized_keys` line, when it has one. Carries both the fingerprint
    /// to compare and the enrollment command to re-offer.
    var publicLine: String = ""
    /// The pinned `100.x` address, when one is configured.
    var fallbackAddress: String = ""

    var kind: AddressKind { AddressKind.of(address) }
}

/// A named, actionable explanation of a failed connection.
///
/// The app never shows a raw transport error. Every failure this app can produce has a
/// name, a sentence that says what is actually wrong, and — where one exists — the exact
/// command that fixes it.
struct Diagnosis: Equatable {
    enum Cause: String, Equatable {
        case sshdOff
        case keyNotAuthorized
        case passwordOnly
        case rsaOnlyHostKey
        case hostKeyChanged
        case magicDNSUnresolved
        case dotLocalUnresolved
        case rateLimited
        case hostAsleep
        case unrecognised
    }

    var cause: Cause
    var title: String
    var explanation: String
    /// A literal, runnable command. Rendered as copyable mono text, never paraphrased.
    var remedy: String?

    /// Whether the enrollment sheet is the next thing to put in front of the user. True
    /// for exactly the three failures that `omarchy-setup-security-sshd` fixes.
    var offersEnrollment: Bool {
        switch cause {
        case .sshdOff, .keyNotAuthorized, .passwordOnly: return true
        default: return false
        }
    }

    /// Whether trying again, on its own, can ever succeed.
    ///
    /// A refused key or a changed host key will be refused identically forever, and
    /// retrying one only spends the firewall's patience. The rest can come back: the box
    /// wakes, Tailscale reconnects, the ufw ban expires, or the user runs the command
    /// this screen just gave them — which is the case worth waiting for.
    var worthRetrying: Bool {
        switch cause {
        case .keyNotAuthorized, .passwordOnly, .rsaOnlyHostKey, .hostKeyChanged:
            return false
        case .sshdOff, .magicDNSUnresolved, .dotLocalUnresolved, .rateLimited,
             .hostAsleep, .unrecognised:
            return true
        }
    }

    /// How much this diagnosis is worth saying when several addresses failed differently.
    ///
    /// Reaching sshd and being refused by it outranks never reaching it: if the MagicDNS
    /// name did not resolve but the pinned address got as far as an authentication
    /// failure, the authentication failure is the thing the user has to fix.
    var rank: Int {
        switch cause {
        case .hostKeyChanged: return 5
        case .keyNotAuthorized, .passwordOnly, .rsaOnlyHostKey: return 4
        case .rateLimited: return 3
        case .sshdOff, .hostAsleep: return 2
        case .magicDNSUnresolved, .dotLocalUnresolved: return 1
        case .unrecognised: return 0
        }
    }

    /// The whole error table, as one pure function.
    static func of(_ facts: ConnectionFacts) -> Diagnosis {
        let fingerprint = OpenSSHWire.fingerprint(ofPublicLine: facts.publicLine)
        let enroll = facts.publicLine.isEmpty
            ? Omarchy.setup
            : Omarchy.enrollCommand(publicLine: facts.publicLine)

        switch facts.outcome {
        case .hostKeyRejected:
            return Diagnosis(
                cause: .hostKeyChanged,
                title: "the host key changed",
                explanation: "\(facts.address) presented a different host key from the one this phone pinned the first time it connected, so the connection was refused before any key of yours was sent. The benign cause is a rebuilt box — a reinstall, or Setup → Reset Computer, both of which run ssh-keygen -A and produce new host keys. The other cause is something else answering to that address. Print the key on the box, compare it with the pin in Settings, and only then forget the old one.",
                remedy: Omarchy.hostKeyCheck)

        case .hostKeyAlgorithm:
            return Diagnosis(
                cause: .rsaOnlyHostKey,
                title: "no host key this app can verify",
                explanation: "Key exchange found no host-key algorithm in common. swift-nio-ssh, the SSH stack under this app, verifies ed25519 and ECDSA host keys and never RSA. A stock Arch install — which is what Omarchy leaves behind, since it ships no sshd_config of its own — has ed25519, ECDSA and RSA all three, so this box has had the others deleted. Regenerating the missing ones puts the ed25519 key back and changes nothing else.",
                remedy: Omarchy.regenerateHostKeys)

        case .noPublicKeyMethod:
            return Diagnosis(
                cause: .passwordOnly,
                title: "that box wants a password",
                explanation: "sshd answered and offered only password or keyboard-interactive authentication. This app is key-only: it has no password field and never sends one. That is not a limitation worth working around here — omarchy-setup-security-sshd writes PasswordAuthentication no into /etc/ssh/sshd_config.d/10-omarchy-hardening.conf as its last step, so a properly set-up Omarchy box does not accept passwords either. Run the enrollment command and this phone's key becomes the way in.",
                remedy: enroll)

        case .publicKeyRejected:
            let mine = fingerprint.map {
                " This phone's key is \($0) — compare it with what the box trusts."
            } ?? ""
            let account = facts.username.isEmpty ? "the account you configured" : facts.username
            return Diagnosis(
                cause: .keyNotAuthorized,
                title: "the box does not know this key",
                explanation: "sshd answered, offered publickey, and refused the one this phone sent as \(account).\(mine) Check that username before you go near the box: sshd deliberately answers a key that is not in ~/.ssh/authorized_keys and an account that does not exist with exactly the same refusal, so a typo in \(account) is indistinguishable from an unenrolled key — and enrolling will appear to work while this screen keeps failing. On the box, id -un prints the real username and \(Omarchy.listAuthorizedKeys) prints every fingerprint that account will accept. The enrollment command below adds this one.",
                remedy: enroll)

        case .nameNotResolved where facts.kind == .bonjour:
            return Diagnosis(
                cause: .dotLocalUnresolved,
                title: "\(facts.address) did not resolve",
                explanation: "A .local name is answered by avahi over the local network, so the phone and the box have to be on the same Wi-Fi — not a guest network, and not one end on cellular. Omarchy enables avahi-daemon and defaults its hostname to omarchy, so omarchy.local works on the LAN and nowhere else. Check the name the box actually has, or put Tailscale on it (\(Omarchy.tailscaleMenuPath)) and reach it from anywhere by its MagicDNS name instead.",
                remedy: Omarchy.hostnameCommand)

        case .nameNotResolved:
            let rescue = facts.fallbackAddress.isEmpty
                ? "There is no pinned fallback address on this host yet; adding one is what stops a failed lookup from being the end of the attempt."
                : "The pinned fallback \(facts.fallbackAddress) is tried next automatically."
            return Diagnosis(
                cause: .magicDNSUnresolved,
                title: "MagicDNS did not answer",
                explanation: "Nothing resolved \(facts.address). MagicDNS only works while Tailscale is connected on this phone, and a third-party app does not always get the tailnet resolver even then. \(rescue) On the box, tailscale ip -4 prints the 100.x address, and the Tailscale bar panel copies a peer's IP with c, its name with n and its DNS name with d.",
                remedy: Omarchy.tailscaleAddress)

        case .connectionRefused, .timedOut:
            if facts.connectionsInWindow >= DialSchedule.connectionsPerWindow {
                return Diagnosis(
                    cause: .rateLimited,
                    title: "waiting — the firewall is rate-limiting",
                    explanation: "Omarchy's SSHD setup runs ufw limit 22/tcp, and that rule bans a source address at six connections in thirty seconds. This phone has opened \(facts.connectionsInWindow) in the last thirty, so the app is spacing the next ones out to stay under the limit. It will reconnect on its own — there is nothing to do here.",
                    remedy: nil)
            }
            if facts.outcome == .timedOut && facts.kind == .bonjour {
                // A `.local` name off the LAN does not fail fast. The lookup goes to
                // avahi, nothing answers it, and the attempt burns the whole connect
                // timeout — so an off-LAN phone lands here rather than on
                // `.nameNotResolved`, and blaming sshd would be a guess.
                return Diagnosis(
                    cause: .dotLocalUnresolved,
                    title: "\(facts.address) did not answer",
                    explanation: "Nothing answered \(facts.address) within \(Omarchy.connectTimeout) seconds, and a .local name cannot say which half failed. Either the name never resolved — avahi answers it over the local network only, so the phone and the box must be on the same Wi-Fi, not a guest one and not one end on cellular — or it resolved and the box is asleep or has SSH switched off. Check both ends are on the same network first, since that is the half this app cannot see. Putting Tailscale on the box (\(Omarchy.tailscaleMenuPath)) and using its MagicDNS name removes the ambiguity and works from anywhere.",
                    remedy: Omarchy.hostnameCommand)
            }
            if facts.outcome == .timedOut && facts.everConnected {
                return Diagnosis(
                    cause: .hostAsleep,
                    title: "the box is not answering",
                    explanation: "\(facts.address) resolved and this phone has connected to it before, but nothing answered within \(Omarchy.connectTimeout) seconds. Omarchy is a laptop distro: a closed lid is a suspended machine, and a suspended machine answers nothing. Open it, or wake it over the network, and this screen will reconnect by itself.",
                    remedy: nil)
            }
            return Diagnosis(
                cause: .sshdOff,
                title: "SSH is switched off on that box",
                explanation: "The address is fine — nothing is listening on port \(Omarchy.port) behind it. That is what a stock Omarchy install looks like: sshd is disabled and the firewall denies everything inbound except LocalSend, so a brand-new box refuses every connection until someone turns SSH on. This is a one-command fix and the command is below: it installs openssh, enables sshd, opens port 22 with ufw limit, and authorizes this phone's key. Open a terminal on the box with \(Omarchy.terminalKeybind) and run it.",
                remedy: enroll)

        case .other(let text):
            // Framed, never bare. A `NIOConnectionError(host:…)` struct printed on its
            // own reads as a crash the user caused; saying whose words these are and
            // what to do with them is the difference between a failure and a bug report.
            return Diagnosis(
                cause: .unrecognised,
                title: "the connection failed",
                explanation: text.isEmpty
                    ? "The connection to \(facts.address) failed and the transport gave no detail at all, which usually means the attempt was torn down from underneath — the phone changed network, or Tailscale reconnected mid-handshake. Trying again is the whole remedy."
                    : "The connection to \(facts.address) failed in a way this app has no name for, so here is what the SSH stack said, verbatim:\n\n\(text)\n\nThat text is from swift-nio-ssh, Citadel or NIO, not from the box, and there is no command here that would fix it. If it repeats, it is worth reporting with this line in it.",
                remedy: nil)
        }
    }
}
