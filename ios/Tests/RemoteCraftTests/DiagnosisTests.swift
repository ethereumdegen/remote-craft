import XCTest

@testable import RemoteCraft

/// The error table is the part of this app a user meets on their worst day, and the only
/// part whose inputs come from a machine that is, by definition, not working. If the
/// mapping is only exercised by breaking a real box, it is not exercised.
///
/// Each case below is a different *observable* situation, and each must produce a
/// different named diagnosis — the whole value of the table is that "no route to the box"
/// and "the box does not want your key" never read the same.
final class DiagnosisTests: XCTestCase {
    private let key = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGFSO8jsBtB5yb9TBe2PxsPPAusNWecJZrp+E9rth6qVu3/KLxOMEIOUUmcsTynO69LEupudKPWRJLpPgq88xCY= remote-craft@iphone"

    private func facts(_ outcome: DialOutcome,
                       address: String = "omarchy.tail1.ts.net",
                       username: String = "andrew",
                       everConnected: Bool = false,
                       attempts: Int = 1) -> ConnectionFacts {
        ConnectionFacts(address: address,
                        username: username,
                        outcome: outcome,
                        everConnected: everConnected,
                        connectionsInWindow: attempts,
                        publicLine: key,
                        fallbackAddress: "100.64.0.9")
    }

    // MARK: - the table

    /// The first failure a new user hits, and the most important message in the app: a
    /// stock Omarchy box has sshd disabled and port 22 closed.
    func testRefusedPortIsSSHDBeingOff() {
        let diagnosis = Diagnosis.of(facts(.connectionRefused))

        XCTAssertEqual(diagnosis.cause, .sshdOff)
        XCTAssertEqual(diagnosis.remedy, Omarchy.enrollCommand(publicLine: key))
        XCTAssertTrue(diagnosis.offersEnrollment)
    }

    /// A box that has never answered and does not answer now is a box with the firewall
    /// up, not a box that fell asleep — `ufw default deny incoming` DROPs rather than
    /// rejects, so "switched off" arrives as a timeout just as often as a refusal.
    func testTimeoutOnANeverSeenBoxIsAlsoSSHDBeingOff() {
        XCTAssertEqual(Diagnosis.of(facts(.timedOut)).cause, .sshdOff)
    }

    /// The same timeout means something else entirely once the box has answered before:
    /// Omarchy is a laptop distro and a closed lid answers nothing.
    func testTimeoutOnAPreviouslySeenBoxIsASleepingHost() {
        let diagnosis = Diagnosis.of(facts(.timedOut, everConnected: true))

        XCTAssertEqual(diagnosis.cause, .hostAsleep)
        XCTAssertNil(diagnosis.remedy)
        XCTAssertTrue(diagnosis.worthRetrying)
    }

    /// The fingerprint has to be in the message: it is the only thing the user can hold
    /// next to what the box prints.
    func testRejectedKeyNamesTheFingerprintAndReOffersEnrollment() {
        let diagnosis = Diagnosis.of(facts(.publicKeyRejected))

        XCTAssertEqual(diagnosis.cause, .keyNotAuthorized)
        XCTAssertTrue(diagnosis.explanation.contains(OpenSSHWire.fingerprint(ofPublicLine: key)!))
        XCTAssertEqual(diagnosis.remedy, Omarchy.enrollCommand(publicLine: key))
        // Nothing about a refused key changes by asking again.
        XCTAssertFalse(diagnosis.worthRetrying)
    }

    /// The failure that wastes the most of a user's evening. sshd answers "that key is
    /// not in this account's authorized_keys" and "there is no such account" with
    /// identical refusals, so a typo'd username reads as an unenrolled key: the user
    /// walks to the box, runs enrollment, watches it succeed, and the phone still fails.
    /// The message has to put the username in front of them and say why.
    func testRejectedKeyNamesTheUsernameAndSaysSSHDCannotTellTheTwoApart() {
        let diagnosis = Diagnosis.of(facts(.publicKeyRejected, username: "andrwe"))

        XCTAssertTrue(diagnosis.explanation.contains("andrwe"),
                      "the username the key was offered for is half of what was refused")
        XCTAssertTrue(diagnosis.explanation.contains("does not exist"),
                      "the message must say sshd cannot distinguish a bad key from a bad account")
    }

    /// A `.local` name off the LAN burns the whole connect timeout rather than failing
    /// fast with EAI_NONAME, so it lands in the timeout branch and would otherwise be
    /// reported as sshd being switched off — sending the user to fix the wrong half.
    func testATimedOutDotLocalNamesBothPossibilities() {
        let diagnosis = Diagnosis.of(facts(.timedOut, address: "omarchy.local"))

        XCTAssertEqual(diagnosis.cause, .dotLocalUnresolved)
        XCTAssertTrue(diagnosis.explanation.contains("same Wi-Fi"))
        XCTAssertTrue(diagnosis.explanation.contains("asleep"))
    }

    func testPasswordOnlyServerIsItsOwnCase() {
        let diagnosis = Diagnosis.of(facts(.noPublicKeyMethod))

        XCTAssertEqual(diagnosis.cause, .passwordOnly)
        XCTAssertEqual(diagnosis.remedy, Omarchy.enrollCommand(publicLine: key))
    }

    func testHostKeyAlgorithmFailureAsksForTheStockHostKeysBack() {
        let diagnosis = Diagnosis.of(facts(.hostKeyAlgorithm))

        XCTAssertEqual(diagnosis.cause, .rsaOnlyHostKey)
        XCTAssertEqual(diagnosis.remedy, "sudo ssh-keygen -A && sudo systemctl restart sshd")
    }

    /// A changed host key is refused and stays refused: no retry, and the remedy is the
    /// command that lets the user verify rather than a way to accept it.
    func testChangedHostKeyRefusesAndOffersVerification() {
        let diagnosis = Diagnosis.of(facts(.hostKeyRejected))

        XCTAssertEqual(diagnosis.cause, .hostKeyChanged)
        XCTAssertEqual(diagnosis.remedy, "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub")
        XCTAssertFalse(diagnosis.worthRetrying)
        XCTAssertFalse(diagnosis.offersEnrollment)
    }

    /// The same failed lookup splits on who was supposed to answer it.
    func testUnresolvedNameSplitsByAddressKind() {
        XCTAssertEqual(Diagnosis.of(facts(.nameNotResolved)).cause, .magicDNSUnresolved)
        XCTAssertEqual(Diagnosis.of(facts(.nameNotResolved, address: "omarchy.local")).cause,
                       .dotLocalUnresolved)
    }

    /// At the cap, a connection-level failure is the firewall, not the box — and saying
    /// so is what stops the user power-cycling a machine that is fine.
    func testRepeatedRapidFailuresAreReportedAsRateLimiting() {
        let diagnosis = Diagnosis.of(facts(.timedOut, attempts: DialSchedule.connectionsPerWindow))

        XCTAssertEqual(diagnosis.cause, .rateLimited)
        XCTAssertTrue(diagnosis.worthRetrying)
        XCTAssertNil(diagnosis.remedy)
    }

    /// Reaching sshd outranks not reaching it: a rate-limit guess must never bury a real
    /// authentication failure, which the ban would not have produced.
    func testRateLimitingDoesNotMaskAnAuthenticationFailure() {
        XCTAssertEqual(Diagnosis.of(facts(.publicKeyRejected, attempts: 9)).cause,
                       .keyNotAuthorized)
    }

    func testEveryOutcomeProducesADistinctCause() {
        let causes = [
            Diagnosis.of(facts(.connectionRefused)).cause,
            Diagnosis.of(facts(.timedOut, everConnected: true)).cause,
            Diagnosis.of(facts(.publicKeyRejected)).cause,
            Diagnosis.of(facts(.noPublicKeyMethod)).cause,
            Diagnosis.of(facts(.hostKeyAlgorithm)).cause,
            Diagnosis.of(facts(.hostKeyRejected)).cause,
            Diagnosis.of(facts(.nameNotResolved)).cause,
            Diagnosis.of(facts(.nameNotResolved, address: "omarchy.local")).cause,
            Diagnosis.of(facts(.timedOut, attempts: 5)).cause,
            Diagnosis.of(facts(.other("something new"))).cause,
        ]

        XCTAssertEqual(Set(causes).count, causes.count)
    }

    /// A key with no derivable public line — an imported RSA key — still gets a remedy,
    /// just the one without a `--key=` in it. A nil command here would be a screen that
    /// says what is wrong and nothing about what to do.
    func testAKeylessHostStillGetsARunnableRemedy() {
        var bare = facts(.connectionRefused)
        bare.publicLine = ""

        XCTAssertEqual(Diagnosis.of(bare).remedy, "omarchy-setup-security-sshd")
    }
}

/// Error text is the only thing three libraries agree to give us, so the classifier is
/// tested against the strings they actually produce rather than against invented ones.
///
/// The three below marked *observed* were captured by pointing a debug build at an
/// address that does not resolve, one that refuses, and one that black-holes, and
/// reading what came back. That matters: `NIOConnectionError` is
/// `CustomStringConvertible`, so what reaches this function is its short form and not
/// the reflected struct dump, and the two spell the same failure completely differently.
final class DialOutcomeTests: XCTestCase {
    /// Observed. Note "nodename", not "hostname" — that is getaddrinfo's wording on
    /// Darwin, and the marker that did not match it sent every failed lookup to
    /// "the connection failed" instead of naming MagicDNS.
    func testResolutionFailureIsRecognised() {
        let observed = "DNS error: SocketAddressError.UnknownHost: nodename nor servname provided, or not known (error 8) for host omarchy.tail1.ts.net, port 22"

        XCTAssertEqual(DialOutcome.classify(observed), .nameNotResolved)
    }

    /// The reflected spelling of the same two failures, which is what arrives wherever
    /// the error is printed without its `CustomStringConvertible` — a nested
    /// `String(describing:)`, or a NIO that predates the conformance.
    func testTheReflectedSpellingsAreRecognisedToo() {
        let dumped = #"NIOConnectionError(host: "omarchy.ts.net", port: 22, dnsAError: Optional(NIOCore.SocketAddressError.unknown(host: "omarchy.ts.net", port: 22)), dnsAAAAError: nil, connectionErrors: [])"#
        let timeout = #"NIOConnectionError(host: "100.64.0.9", port: 22, connectionErrors: [NIOPosix.SingleConnectionFailure(target: [IPv4]100.64.0.9/100.64.0.9:22, error: connectTimeout(NIOCore.TimeAmount(nanoseconds: 10000000000)))])"#

        XCTAssertEqual(DialOutcome.classify(dumped), .nameNotResolved)
        XCTAssertEqual(DialOutcome.classify(timeout), .timedOut)
    }

    /// Observed, both. A timeout reported as an unnamed failure is the worst of the
    /// three: the retry loop treats an unnamed failure as a transient one, so a
    /// sleeping laptop would be redialled without ever being called asleep.
    func testRefusalAndTimeoutAreNotTheSameThing() {
        let refused = "Connection errors: NIOPosix.SingleConnectionFailure(target: [IPv4]127.0.0.1/127.0.0.1:9, error: connection reset (error set): Connection refused (errno: 61))"
        let timeout = "Connect timeout (10 s)"

        XCTAssertEqual(DialOutcome.classify(refused), .connectionRefused)
        XCTAssertEqual(DialOutcome.classify(timeout), .timedOut)
    }

    func testCitadelAndNIOSSHAuthenticationFailuresAreRecognised() {
        XCTAssertEqual(DialOutcome.classify("allAuthenticationOptionsFailed"), .publicKeyRejected)
        XCTAssertEqual(DialOutcome.classify("AuthenticationFailed()"), .publicKeyRejected)
        XCTAssertEqual(DialOutcome.classify("unsupportedPrivateKeyAuthentication"),
                       .noPublicKeyMethod)
    }

    func testHostKeyFailuresOutrankTheirSurroundingConnectionError() {
        XCTAssertEqual(DialOutcome.classify("NIOSSHError.keyExchangeNegotiationFailure"),
                       .hostKeyAlgorithm)
        // The only host-key rejection this app can produce: `TrustOnFirstUse` fails the
        // validation promise with `SSHError.hostKeyChanged`, and NIO hands it back
        // wrapped in the connection error of the socket it was validating.
        let wrapped = #"NIOConnectionError(host: "omarchy.ts.net", port: 22, connectionErrors: [NIOPosix.SingleConnectionFailure(target: [IPv4]100.64.0.9/100.64.0.9:22, error: hostKeyChanged("omarchy.ts.net"))])"#
        XCTAssertEqual(DialOutcome.classify(wrapped), .hostKeyRejected)
    }

    /// The ordering that matters most and is least obvious. A `NIOConnectionError`
    /// description carries the DNS errors for both address families *and* the per-address
    /// connection errors in one string, so a host whose A record is missing while its
    /// AAAA resolves and then refuses matches the DNS marker and the refusal marker at
    /// once. Reporting that as "MagicDNS did not answer" sends the user to debug a
    /// resolver that is working while their box sits there refusing connections.
    func testAPartialLookupFailureIsReportedByWhatTheSocketDidNotByDNS() {
        let refusedOverIPv6 = #"NIOConnectionError(host: "omarchy.ts.net", port: 22, dnsAError: Optional(NIOCore.SocketAddressError.unknown(host: "omarchy.ts.net", port: 22)), dnsAAAAError: nil, connectionErrors: [NIOPosix.SingleConnectionFailure(target: [IPv6]omarchy.ts.net/[fd7a::1]:22, error: connection reset (error set): Connection refused (errno: 61))])"#
        let timedOutOverIPv6 = #"NIOConnectionError(host: "omarchy.ts.net", port: 22, dnsAError: Optional(NIOCore.SocketAddressError.unknown(host: "omarchy.ts.net", port: 22)), dnsAAAAError: nil, connectionErrors: [NIOPosix.SingleConnectionFailure(target: [IPv6]omarchy.ts.net/[fd7a::1]:22, error: connectTimeout(NIOCore.TimeAmount(nanoseconds: 10000000000)))])"#

        XCTAssertEqual(DialOutcome.classify(refusedOverIPv6), .connectionRefused)
        XCTAssertEqual(DialOutcome.classify(timedOutOverIPv6), .timedOut)
    }

    /// And the converse: with no `connectionErrors` entry nothing was ever dialled, so
    /// the lookup really is the failure.
    func testALookupThatProducedNoAddressAtAllIsStillADNSFailure() {
        let text = #"NIOConnectionError(host: "omarchy.ts.net", port: 22, dnsAError: Optional(NIOCore.SocketAddressError.unknown(host: "omarchy.ts.net", port: 22)), dnsAAAAError: Optional(NIOCore.SocketAddressError.unknown(host: "omarchy.ts.net", port: 22)), connectionErrors: [])"#

        XCTAssertEqual(DialOutcome.classify(text), .nameNotResolved)
    }

    func testAnythingElseKeepsItsText() {
        XCTAssertEqual(DialOutcome.classify("a brand new failure"), .other("a brand new failure"))
    }

    func testAddressKinds() {
        XCTAssertEqual(AddressKind.of("omarchy"), .magicDNS)
        XCTAssertEqual(AddressKind.of("omarchy.tail1234.ts.net"), .magicDNS)
        XCTAssertEqual(AddressKind.of("omarchy.local"), .bonjour)
        XCTAssertEqual(AddressKind.of("100.64.0.9"), .tailnetIP)
        XCTAssertEqual(AddressKind.of("192.168.1.8"), .other)
    }
}
