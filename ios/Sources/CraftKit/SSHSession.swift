import Citadel
import Foundation
import NIOCore
import NIOSSH

/// The box answered. What it answered with, and on which address.
struct Attached: Equatable {
    /// The address that actually answered, which is not always the one the user typed —
    /// see `SSHHost.fallbackAddress`.
    let address: String
    /// The host key's `SHA256:…` fingerprint, for the user to compare with the box.
    let fingerprint: String?
    /// True the first time an address is seen, when the key was pinned rather than
    /// checked. That is the one moment the fingerprint is worth putting on screen.
    let newlyPinned: Bool
}

/// What a shell session tells the screen above it.
///
/// Deliberately not a UI type: the transport says what happened, the store decides what it
/// looks like. Failure is its own case and carries a `Diagnosis` rather than a string,
/// because "the terminal stopped" with no explanation is the single most useless thing
/// this app could show — and a raw `NIOConnectionError()` is barely better.
enum ShellEvent {
    case opened(Attached)
    case data([UInt8])
    /// An orderly end: the user disconnected, or the remote shell exited.
    case closed(String)
    /// The connection could not be made, or died. Always named, always actionable.
    case failed(Diagnosis)
}

enum SSHError: LocalizedError {
    case noAddress
    case noKey
    case hostKeyChanged(String)
    /// A connection failure that has already been turned into a named diagnosis.
    case diagnosed(Diagnosis)

    var errorDescription: String? {
        switch self {
        case .noAddress:
            return "This host has no address. Add its MagicDNS name, its 100.x address, or omarchy.local."
        case .noKey:
            return "This host has no key. Pick one in Keys, or generate one and enroll it on the box."
        case .hostKeyChanged(let address):
            return "The host key for \(address) changed."
        case .diagnosed(let diagnosis):
            return diagnosis.title
        }
    }
}

/// Pins a host key the first time it is seen and refuses it if it ever changes.
///
/// TOFU, the same rule the `ssh` binary uses, for the same reason: nobody has a fingerprint
/// to compare against on a phone until the first connection gives them one, and accepting
/// anything forever is how a tailnet gets man-in-the-middled by a machine that took over
/// the name. The pin is keyed by address, so the MagicDNS name and the pinned `100.x`
/// address of one box get one entry each — they are separate names and OpenSSH treats them
/// separately too.
///
/// The pin lives in the Keychain. It used to live in `UserDefaults`, which meant a pin
/// could be dropped by anything that cleared preferences and the app would silently
/// re-trust whatever answered next; existing pins are adopted on first use rather than
/// discarded, because a silent re-TOFU is exactly the failure this class exists to prevent.
final class TrustOnFirstUse: NIOSSHClientServerAuthenticationDelegate {
    private let address: String
    private let account: String

    /// Whether this address was already pinned before this attempt. A box that has
    /// answered before is a box that can be asleep rather than switched off.
    let hadPin: Bool

    /// Set when validation fails, so the connect loop can name the failure even though
    /// NIO reports it as a generic handshake error one layer down.
    private(set) var mismatched = false
    private(set) var fingerprint: String?
    private(set) var pinnedNow = false

    init(address: String, port: Int) {
        self.address = address
        self.account = Secret.hostKey(address: address, port: port)
        Self.adoptLegacyPin(address: address, port: port)
        self.hadPin = Keychain.load(account) != nil
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let offered = String(openSSHPublicKey: hostKey)
        fingerprint = OpenSSHWire.fingerprint(ofPublicLine: offered)

        guard let pinned = Keychain.load(account) else {
            Keychain.save(offered, as: account)
            pinnedNow = true
            validationCompletePromise.succeed(())
            return
        }
        if pinned == offered {
            validationCompletePromise.succeed(())
        } else {
            mismatched = true
            validationCompletePromise.fail(SSHError.hostKeyChanged(address))
        }
    }

    static func pin(address: String, port: Int) -> String? {
        Keychain.load(Secret.hostKey(address: address, port: port))
    }

    /// Drop the pin for an address. A rebuilt box — a reinstall, or Setup → Reset
    /// Computer — is a real and unremarkable event, and the alternative is an app that
    /// can never connect again. Deliberately not reachable from a failure screen: it is
    /// in Settings, behind a typed confirmation, because one tap is not a decision.
    static func forget(address: String, port: Int) {
        Keychain.delete(Secret.hostKey(address: address, port: port))
        UserDefaults.standard.removeObject(forKey: legacySlot(address: address, port: port))
    }

    /// Every pinned address, for Settings to list.
    static func pinnedAddresses() -> [String] {
        Keychain.accounts(prefix: "hostkey.").map {
            String($0.dropFirst("hostkey.".count))
        }
    }

    /// The same two operations addressed by the `address:port` string Settings lists,
    /// so a screen showing pins does not have to take them apart and put them back
    /// together — an address can contain colons, and a split that works for
    /// `omarchy.local:22` is a bug waiting for an IPv6 literal.
    static func pin(slot: String) -> String? {
        Keychain.load("hostkey.\(slot)")
    }

    static func forget(slot: String) {
        Keychain.delete("hostkey.\(slot)")
        UserDefaults.standard.removeObject(forKey: "rc.hostkey.\(slot)")
    }

    private static func legacySlot(address: String, port: Int) -> String {
        "rc.hostkey.\(address):\(port)"
    }

    private static func adoptLegacyPin(address: String, port: Int) {
        let slot = legacySlot(address: address, port: port)
        guard let old = UserDefaults.standard.string(forKey: slot) else { return }
        let account = Secret.hostKey(address: address, port: port)
        if Keychain.load(account) == nil {
            Keychain.save(old, as: account)
        }
        UserDefaults.standard.removeObject(forKey: slot)
    }
}

/// Wraps an authentication delegate to record what the server was actually willing to do.
///
/// Without this, "the key was refused" and "the box never offered key authentication at
/// all" arrive as the same failure, and they need opposite advice: one means enroll this
/// key, the other means the box is in a state Omarchy's own setup script would fix. The
/// server's method list is only ever shown to the delegate, so observing it means sitting
/// in front of one.
final class OfferedMethods: NIOSSHClientUserAuthenticationDelegate {
    private let inner: NIOSSHClientUserAuthenticationDelegate
    /// Nil until the server has said anything at all — i.e. the handshake never got far
    /// enough to ask, which is itself the distinction between a network failure and a
    /// refusal.
    private(set) var publicKeyOffered: Bool?

    init(_ inner: NIOSSHClientUserAuthenticationDelegate) {
        self.inner = inner
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // The first list is the honest one: later rounds narrow as methods are spent.
        if publicKeyOffered == nil {
            publicKeyOffered = availableMethods.contains(.publicKey)
        }
        inner.nextAuthenticationType(availableMethods: availableMethods,
                                     nextChallengePromise: nextChallengePromise)
    }
}

/// Applies Omarchy's own liveness expectations to the socket.
///
/// Omarchy's shipped `~/.ssh/config` uses `ServerAliveInterval 15` and
/// `ServerAliveCountMax 3`: a link that stops carrying traffic is declared dead in about
/// forty-five seconds rather than hanging until TCP gives up minutes later. This app has
/// no SSH-level keepalive to send — the PTY belongs to the user, and writing anything
/// into it would type into their shell — so the same policy goes on the socket itself,
/// where the kernel sends the probes and errors the connection when they go unanswered.
/// The channel then closes, the PTY loop ends, and the store reconnects on schedule.
final class Keepalive: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel
        channel.setOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .whenComplete { _ in }
        channel.setOption(ChannelOptions.tcpOption(.init(rawValue: TCP_KEEPALIVE)),
                          value: SocketOptionValue(Omarchy.keepaliveInterval))
            .whenComplete { _ in }
        channel.setOption(ChannelOptions.tcpOption(.init(rawValue: TCP_KEEPINTVL)),
                          value: SocketOptionValue(Omarchy.keepaliveInterval))
            .whenComplete { _ in }
        channel.setOption(ChannelOptions.tcpOption(.init(rawValue: TCP_KEEPCNT)),
                          value: SocketOptionValue(Omarchy.keepaliveMisses))
            .whenComplete { _ in }
        context.fireChannelActive()
    }
}

/// Charged immediately before each TCP connection, so the dial schedule counts what ufw
/// counts. Returns how many connections this phone has opened inside the current window,
/// which is what tells a refusal apart from a self-inflicted ban.
///
/// Per-address rather than per-attempt: one attempt on a host with a MagicDNS name and a
/// pinned fallback opens two sockets, and charging one of them is how an app bans itself.
typealias ConnectionBudget = (String) async -> Int

/// Connecting, with the MagicDNS fallback actually performed rather than merely recorded,
/// and with every failure named before it leaves this file.
enum SSHDial {
    /// Try each candidate address in order and return the first that answers.
    ///
    /// A name that does not resolve fails fast, so putting the MagicDNS name first costs
    /// nothing when it is broken and is worth having when it works — it is the address the
    /// user's `known_hosts` and ACLs are written in terms of.
    ///
    /// When several addresses fail differently, the most informative diagnosis wins rather
    /// than the last one: an unresolvable name followed by a rejected key means the user
    /// has a key problem, not a DNS problem.
    static func connect(host: SSHHost, keys: [KeyRecord],
                        charge: @escaping ConnectionBudget) async throws -> (SSHClient, Attached) {
        let addresses = host.candidates()
        guard !addresses.isEmpty else { throw SSHError.noAddress }
        guard let key = keys.first(where: { $0.id == host.keyID }) else { throw SSHError.noKey }

        var worst: Diagnosis?
        for address in addresses {
            let inWindow = await charge(address)
            let methods = OfferedMethods(try KeyVault.authentication(for: key, username: host.username))
            let validator = TrustOnFirstUse(address: address, port: host.port)
            do {
                let client = try await SSHClient.connect(
                    host: address,
                    port: host.port,
                    authenticationMethod: .custom(methods),
                    hostKeyValidator: .custom(validator),
                    // `.never`: reconnection is this app's job, not the library's. Citadel
                    // would reconnect a socket underneath a PTY whose remote shell is
                    // already gone, which looks alive and is not — and it would do it
                    // without counting attempts against ufw's rate limit.
                    reconnect: .never,
                    channelHandlers: [Keepalive()],
                    connectTimeout: .seconds(Omarchy.connectTimeout))
                return (client, Attached(address: address,
                                         fingerprint: validator.fingerprint,
                                         newlyPinned: validator.pinnedNow))
            } catch {
                let diagnosis = Diagnosis.of(ConnectionFacts(
                    address: address,
                    username: host.username,
                    outcome: outcome(of: error, validator: validator, methods: methods),
                    everConnected: validator.hadPin,
                    connectionsInWindow: inWindow,
                    publicLine: key.publicLine,
                    fallbackAddress: host.fallbackAddress))
                if diagnosis.rank >= (worst?.rank ?? -1) { worst = diagnosis }
            }
        }
        throw SSHError.diagnosed(worst ?? Diagnosis.of(ConnectionFacts(address: addresses[0],
                                                                      username: host.username)))
    }

    /// What one failed attempt observably was.
    ///
    /// The two delegates are asked first: they watched the handshake from inside and know
    /// things the error text cannot express — that the key was pinned and did not match,
    /// or that the server never offered publickey at all.
    static func outcome(of error: Error,
                        validator: TrustOnFirstUse,
                        methods: OfferedMethods) -> DialOutcome {
        if validator.mismatched { return .hostKeyRejected }
        if methods.publicKeyOffered == false { return .noPublicKeyMethod }
        return DialOutcome.classify("\(error)")
    }
}

/// One interactive PTY on one box.
///
/// `@MainActor` on purpose. Everything it hands out — terminal bytes — has to reach
/// SwiftTerm on the main thread anyway, and the alternative (a background actor hopping to
/// the main one per chunk) buys nothing: the awaits inside never block the main thread,
/// NIO does its work on its own event loops.
///
/// Writes go through a single outbox rather than a `Task` per keystroke. Two tasks awaiting
/// the same channel can complete in either order, and a terminal that transposes two
/// characters of a typed command is worse than one that is slow.
@MainActor
final class ShellSession {
    private enum Outbound {
        case bytes([UInt8])
        case size(cols: Int, rows: Int)
    }

    private var runner: Task<Void, Never>?
    private var outbox: AsyncStream<Outbound>.Continuation?
    private var client: SSHClient?
    /// Set when `stop()` was called, so the closing event says "closed" and not "the
    /// connection dropped" — the user pressed the button, they know why.
    private var userClosed = false

    private(set) var isRunning = false

    func start(host: SSHHost, keys: [KeyRecord], cols: Int, rows: Int,
               charge: @escaping ConnectionBudget,
               sink: @escaping (ShellEvent) -> Void) {
        stop()
        userClosed = false
        isRunning = true

        let (stream, continuation) = AsyncStream<Outbound>.makeStream(bufferingPolicy: .unbounded)
        outbox = continuation

        runner = Task { [weak self] in
            defer { self?.isRunning = false }
            do {
                let (client, attached) = try await SSHDial.connect(
                    host: host, keys: keys, charge: charge)
                // `runner?.cancel()` cannot abort the connect above: Citadel bridges an
                // `EventLoopFuture` and never checks cancellation, so a disconnect made
                // while a dial is in flight still finishes authenticating. Without this
                // the client is assigned to a session nobody holds, opens a PTY and
                // parks forever — a live login shell on the box that nothing will close.
                guard let self, !self.userClosed, !Task.isCancelled else {
                    try? await client.close()
                    sink(.closed("closed"))
                    return
                }
                self.client = client

                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    // xterm-256color, not xterm: the box is Omarchy, everything on it is
                    // themed, and TERM=xterm makes a 256-colour prompt render as mud.
                    term: "xterm-256color",
                    terminalCharacterWidth: cols,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:]))

                try await client.withPTY(request) { inbound, outbound in
                    sink(.opened(attached))

                    let pump = Task {
                        for await item in stream {
                            switch item {
                            case .bytes(let bytes):
                                try? await outbound.write(ByteBuffer(bytes: bytes))
                            case .size(let cols, let rows):
                                try? await outbound.changeSize(cols: cols, rows: rows,
                                                               pixelWidth: 0, pixelHeight: 0)
                            }
                        }
                    }
                    defer { pump.cancel() }

                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            // stderr is merged on purpose: a PTY has one screen, and the
                            // remote side already decided what goes where.
                            sink(.data(Array(buffer.readableBytesView)))
                        }
                    }
                }
                sink(.closed(self.userClosed ? "closed" : "the remote shell exited"))
            } catch is CancellationError {
                sink(.closed("closed"))
            } catch {
                if self?.userClosed == true {
                    sink(.closed("closed"))
                } else if let ssh = error as? SSHError, case .diagnosed(let diagnosis) = ssh {
                    sink(.failed(diagnosis))
                } else {
                    sink(.closed(Self.describe(error)))
                }
            }
        }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        outbox?.yield(.bytes(Array(bytes)))
    }

    func resize(cols: Int, rows: Int) {
        outbox?.yield(.size(cols: cols, rows: rows))
    }

    /// Authorize one more public key on the box this session is already talking to.
    ///
    /// A passthrough rather than a `client` accessor on purpose. Handing the
    /// `SSHClient` out would hand out `close()` with it, and one stray close ends the
    /// user's PTY — the shell, its scrollback, and whatever was running in it — for the
    /// sake of appending a line to a file. `stop()` stays the only way a session ends,
    /// which is the same rule that makes the epoch checks in `TerminalStore` sound.
    ///
    /// Costs no connection: SSH multiplexes, so the exec channel `RemoteEnroll` opens
    /// rides the socket that is already up and never reaches ufw's six-per-thirty-
    /// seconds counter.
    func authorize(line: String, address: String) async -> AuthorizeResult {
        guard let client else {
            return .failed("The terminal is not connected to that box any more, so there was nothing to authorize over.")
        }
        return await RemoteEnroll.authorize(line: line, over: client, address: address)
    }

    func stop() {
        userClosed = true
        outbox?.finish()
        outbox = nil
        runner?.cancel()
        runner = nil
        isRunning = false
        if let client {
            self.client = nil
            Task { try? await client.close() }
        }
    }

    /// The errors that are not connection failures: a host with no key, a key whose
    /// material has gone. They already say what to do, and there is nothing to diagnose —
    /// nothing was dialled.
    static func describe(_ error: Error) -> String {
        if let ssh = error as? SSHError { return ssh.localizedDescription }
        if let keyed = error as? KeyError { return keyed.localizedDescription }
        return "\(error)"
    }
}
