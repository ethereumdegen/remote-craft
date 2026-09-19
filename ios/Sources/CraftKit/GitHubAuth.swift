import Foundation
import Observation

/// Which GitHub app registration this build talks to.
///
/// The device flow exists so a phone can authenticate with **no client secret and no
/// backend of ours**: the client id is public, the user types an eight-character code at
/// `github.com/login/device`, and GitHub hands the token to the app that is polling. A
/// secret would have to ship inside the IPA, where it is not a secret, so the whole
/// design here is shaped around not having one.
///
/// The id comes from `Info.plist` under `RCGitHubClientID` rather than a literal, because
/// a fork of this app has a different registration and a hard-coded id makes that a code
/// change. A value still holding `$(…)` is treated as absent: an unsubstituted build
/// setting is the normal way this key ends up wrong, and sending the literal string
/// `$(RC_GITHUB_CLIENT_ID)` to GitHub earns `incorrect_client_credentials` several
/// screens later instead of a straight answer here.
///
/// **The scope only means something to an OAuth App.** `write:public_key` is what an
/// OAuth App needs to `POST /user/keys`. A **GitHub App** ignores scopes entirely: it
/// must be registered with the fine-grained *"Git SSH keys"* user permission set to
/// **write**, and with **Device flow enabled** in its settings. Get the permission wrong
/// and publishing fails with 403; get device flow wrong and login fails with
/// `device_flow_disabled`. Neither is visible anywhere until a user is standing in front
/// of the failure, which is why both are named in the strings this file produces.
enum GitHubApp {
    /// The `Info.plist` key. Named here so the error message can say it.
    static let infoKey = "RCGitHubClientID"

    /// OAuth App scope for `POST /user/keys`. Ignored by a GitHub App — see above.
    static let scope = "write:public_key"

    static var clientID: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: infoKey) as? String) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("$(") ? "" : trimmed
    }

    static var isConfigured: Bool { !clientID.isEmpty }

    /// What to say when there is nothing to send. Shown rather than a silent no-op: a
    /// button that does nothing is indistinguishable from a network that is down.
    static let unconfigured =
        "This build has no GitHub client id. Set \(infoKey) in Info.plist."
}

/// A device-flow challenge: the code the user types, and the code this app polls with.
///
/// The two codes are not interchangeable and confusing them is the classic mistake — the
/// eight-character `user_code` is for the human, the forty-character `device_code` is the
/// poll credential and must never be shown.
///
/// `expiresAt` is an absolute deadline computed at parse time from `expires_in` (900s by
/// default) instead of a countdown of attempts. Polling is paced by the server — `interval`
/// seconds, raised whenever GitHub says `slow_down` — so the number of attempts in a
/// window is not knowable in advance, and a loop that counted them would either give up
/// early or poll a dead code forever.
struct DeviceCode: Equatable {
    let userCode: String
    let deviceCode: String
    let verificationURL: URL
    let interval: TimeInterval
    let expiresAt: Date
}

/// What `POST /login/device/code` did.
///
/// Shaped like `GitHubKeys` rather than a `Result`, and for the same reason: the two
/// non-network failures here are setup mistakes with a specific fix, and a `Result`
/// whose failure is a string flattens them into the same prose as a timeout. A missing
/// `RCGitHubClientID` means this build was assembled wrong; `device_flow_disabled` means
/// the registration exists but never had the switch turned on. Both are invisible until
/// a user hits them, both are fixed somewhere other than the phone, and neither is worth
/// retrying — which is exactly the decision a caller cannot make from a string.
enum DeviceCodeRequest: Equatable {
    case issued(DeviceCode)
    /// `RCGitHubClientID` is empty in this build — a setup error, not a network one.
    case notConfigured
    /// `device_flow_disabled`: the registration exists but has not enabled device flow.
    case disabled
    case failed(String)

    /// One line, the way the sign-in screen says it.
    var summary: String {
        switch self {
        case .issued(let code):
            return "Enter \(code.userCode) at \(code.verificationURL.absoluteString)."
        case .notConfigured:
            return GitHubApp.unconfigured
        case .disabled:
            return "This GitHub app registration does not have device flow enabled. Turn on \"Device flow\" in its settings."
        case .failed(let why):
            return why
        }
    }
}

/// One answer from one poll of `/login/oauth/access_token`.
///
/// `pending` and `slowDown` are both "keep going", and keeping them apart is the point:
/// `slow_down` means GitHub has already decided this client is polling too fast, and
/// treating it as an ordinary pending tick — the obvious simplification — keeps the
/// offending rate exactly as it was and gets the request rejected again.
enum DevicePoll: Equatable {
    case pending
    case slowDown
    case token(String)
    case denied
    case expired
    case failed(String)
}

/// What `POST /user/keys` did with this phone's public key.
///
/// `alreadyPresent` is a success, not a consolation. GitHub answers **422 validation
/// failed** for a key that is already on the account, and enrollment is re-run all the
/// time — the app crashed, the user backed out of the sheet, the box was rebuilt. Failing
/// there would strand a user whose key is already exactly where it needs to be, with no
/// action available that could fix it.
enum PublishOutcome: Equatable {
    case published
    case alreadyPresent
    case unauthorized
    case forbidden
    case failed(String)

    /// One line, the way the enrollment screen says it.
    var summary: String {
        switch self {
        case .published:
            return "Key published to GitHub — `--gh-keys` will authorize this phone."
        case .alreadyPresent:
            return "GitHub already has this key — `--gh-keys` will authorize this phone."
        case .unauthorized:
            return "GitHub refused the token (401). It was revoked or expired — sign in again."
        case .forbidden:
            return "That token may not write SSH keys (403). An OAuth App needs the `write:public_key` scope; a GitHub App needs the \"Git SSH keys\" user permission set to write."
        case .failed(let why):
            return why
        }
    }

    /// Both success shapes mean the key is on the account, which is the only fact
    /// `--gh-keys` cares about. Everything else leaves the box unable to authorize this
    /// phone, and the screen has to stay on the failure rather than advance.
    var isUsable: Bool {
        switch self {
        case .published, .alreadyPresent: return true
        case .unauthorized, .forbidden, .failed: return false
        }
    }
}

/// GitHub's device flow, and publishing one SSH public key with the token it yields.
///
/// Three endpoints, no secret, no backend:
/// 1. `POST https://github.com/login/device/code` → a `DeviceCode`.
/// 2. `POST https://github.com/login/oauth/access_token`, polled → a user token.
/// 3. `POST https://api.github.com/user/keys` → this phone's Enclave key on the account,
///    where `omarchy-setup-security-sshd --gh-keys` will find it.
///
/// Step 3 is the whole reason the other two exist. Omarchy's `--gh-keys` route `curl`s
/// `github.com/<user>.keys` once, at the moment it runs, so "use my GitHub keys" only
/// helps a phone whose key is *already* published — see `GitHubKeys`, which exists to
/// tell the user when it is not. This is how it gets there without walking to a laptop.
///
/// Every classifier below is a pure function of a status code and some bytes. Nothing
/// here can be exercised against GitHub in a test — device flow needs a human at a
/// keyboard — so the parsing and the branch table are separated from the transport and
/// tested with literals, and the network functions are kept thin enough to read.
enum GitHubAuth {
    static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    static let keysURL = URL(string: "https://api.github.com/user/keys")!
    static let userURL = URL(string: "https://api.github.com/user")!

    /// The device-code grant type, spelled the one way GitHub accepts.
    static let grantType = "urn:ietf:params:oauth:grant-type:device_code"

    /// GitHub's documented defaults, used when a reply omits the field.
    static let defaultInterval: TimeInterval = 5
    static let defaultLifetime: TimeInterval = 900

    /// Added to the poll interval on `slow_down`, per GitHub's documentation.
    static let slowDownPenalty: TimeInterval = 5

    // MARK: - pure classifiers

    /// Read the reply to `POST /login/device/code`.
    ///
    /// `now` is a parameter with a default so this stays a function of its inputs: the
    /// deadline is the one thing in the parse that is not in the bytes, and a test that
    /// cannot say what time it is cannot assert on `expiresAt` at all.
    ///
    /// An `error` field is checked before the status, because this endpoint answers 200
    /// with `{"error":"device_flow_disabled"}` when the registration never enabled device
    /// flow — a 200 whose body is a refusal, and the first thing a developer wiring up a
    /// new client id hits.
    static func read(deviceCodeStatus status: Int,
                     body: Data,
                     now: Date = Date()) -> DeviceCodeRequest {
        guard let fields = fields(body) else {
            return .failed("GitHub answered \(status)")
        }
        // Checked before the `error` field. A client id GitHub has never seen earns a
        // 404 whose body is `{"error":"Not Found"}` — verified against the live
        // endpoint — and "GitHub said Not Found." is the wrong sentence for the one
        // mistake every new deployment makes first. The token endpoint uses
        // `incorrect_client_credentials` for the same cause; this one does not.
        guard status != 404 else {
            return .failed("GitHub does not recognize this client id. Check \(GitHubApp.infoKey) in Info.plist.")
        }
        if let error = fields["error"] as? String {
            return error == "device_flow_disabled"
                ? .disabled
                : .failed(explain(error, fields["error_description"] as? String))
        }
        guard status == 200 else {
            return .failed("GitHub answered \(status)")
        }
        guard let deviceCode = fields["device_code"] as? String, !deviceCode.isEmpty,
              let userCode = fields["user_code"] as? String, !userCode.isEmpty,
              let verification = fields["verification_uri"] as? String,
              let url = URL(string: verification) else {
            return .failed("GitHub's device-code reply was missing fields.")
        }
        // Floored at one second: an interval of zero — or a missing one read as zero —
        // turns the caller's schedule into a spin against a rate-limited endpoint.
        let interval = max(fields["interval"] as? TimeInterval ?? defaultInterval, 1)
        let lifetime = max(fields["expires_in"] as? TimeInterval ?? defaultLifetime, interval)
        return .issued(DeviceCode(userCode: userCode,
                                  deviceCode: deviceCode,
                                  verificationURL: url,
                                  interval: interval,
                                  expiresAt: now.addingTimeInterval(lifetime)))
    }

    /// Read one reply to `POST /login/oauth/access_token`.
    ///
    /// The token is checked first and the `error` field second, because this endpoint
    /// signals refusal in the *body* — usually with HTTP 200 — and a reader that switched
    /// on the status alone would report success for every `authorization_pending` tick in
    /// a login the user has not completed yet.
    ///
    /// A body that is not JSON at all falls through to the status. GitHub's edge serves
    /// HTML on some 5xx, and `JSONSerialization` handed that returns nil rather than
    /// throwing anything a `catch` here would see.
    static func read(pollStatus status: Int, body: Data) -> DevicePoll {
        guard let fields = fields(body) else {
            return .failed("GitHub answered \(status)")
        }
        if let token = fields["access_token"] as? String, !token.isEmpty {
            return .token(token)
        }
        guard let error = fields["error"] as? String else {
            return status == 200
                ? .failed("GitHub's reply carried neither a token nor an error.")
                : .failed("GitHub answered \(status)")
        }
        switch error {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown
        case "access_denied":
            return .denied
        case "expired_token":
            return .expired
        default:
            return .failed(explain(error, fields["error_description"] as? String))
        }
    }

    /// Read the reply to `POST /user/keys`.
    ///
    /// 201 is created. **422 is the already-on-the-account case** and is read as success
    /// — see `PublishOutcome`. GitHub uses 422 for any validation failure on this
    /// endpoint, so a genuinely malformed key would also land here and be reported as
    /// present; that trade is taken deliberately, because the app only ever sends a line
    /// it generated itself from a Secure Enclave key, while a user re-running enrollment
    /// is routine. The box tells the truth either way: `--gh-keys` authorizes what is
    /// actually published, and a connection attempt is the real test.
    static func read(publishStatus status: Int, body: Data) -> PublishOutcome {
        switch status {
        case 200, 201:
            return .published
        case 422:
            return .alreadyPresent
        case 401:
            return .unauthorized
        case 403:
            return .forbidden
        default:
            if let message = fields(body)?["message"] as? String, !message.isEmpty {
                return .failed("GitHub answered \(status): \(message)")
            }
            return .failed("GitHub answered \(status)")
        }
    }

    // MARK: - network

    /// Start a login. One request; the caller then shows `userCode` and polls.
    ///
    /// An unconfigured build is answered without touching the network: there is nothing
    /// to send, and GitHub's reply to an empty client id would be a worse description of
    /// the problem than this app's own.
    static func requestDeviceCode() async -> DeviceCodeRequest {
        guard GitHubApp.isConfigured else { return .notConfigured }
        let request = form(url: deviceCodeURL,
                           pairs: [("client_id", GitHubApp.clientID),
                                   ("scope", GitHubApp.scope)])
        switch await send(request) {
        case .answered(let status, let body):
            return read(deviceCodeStatus: status, body: body)
        case .offline(let why):
            return .failed(why)
        }
    }

    /// Poll **once**. No sleeping, no looping.
    ///
    /// The schedule belongs to the caller, which is the only place that knows the
    /// interval, the `slow_down` penalty and `expiresAt`. A helper that drove its own
    /// loop would hold a network call for up to fifteen minutes, be untestable without
    /// waiting out a real login, and could only be stopped by cancelling a task in the
    /// middle of a request.
    ///
    /// A transport failure is reported as `pending`, not `failed`. A single dropped
    /// request over fifteen minutes on a phone — screen locked, cell handover, Wi-Fi
    /// swap — is expected, and aborting a login the user has already half-completed on
    /// another device because of one is worse than trying again in `interval` seconds.
    /// The deadline still ends it: the caller stops at `expiresAt` either way.
    static func poll(_ code: DeviceCode) async -> DevicePoll {
        guard GitHubApp.isConfigured else { return .failed(GitHubApp.unconfigured) }
        let request = form(url: tokenURL,
                           pairs: [("client_id", GitHubApp.clientID),
                                   ("device_code", code.deviceCode),
                                   ("grant_type", grantType)])
        switch await send(request) {
        case .answered(let status, let body):
            return read(pollStatus: status, body: body)
        case .offline:
            return .pending
        }
    }

    /// Put one OpenSSH public line on the signed-in account.
    ///
    /// The line is trimmed and refused when empty rather than posted: GitHub answers 422
    /// for an empty key, which this file reads as "already present", and that is the one
    /// input that would turn the deliberate 422 rule into a lie.
    static func publish(line: String, title: String, token: String) async -> PublishOutcome {
        let key = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failed("This key has no public line to publish.") }
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = ["title": label.isEmpty ? "remote-craft" : label, "key": key]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failed("This key's title could not be encoded.")
        }

        var request = URLRequest(url: keysURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        api(&request, token: token)

        switch await send(request) {
        case .answered(let status, let body):
            return read(publishStatus: status, body: body)
        case .offline(let why):
            return .failed(why)
        }
    }

    /// The account a token belongs to, via `GET /user`.
    ///
    /// Asked for once and stored, because the login is what `--gh-keys <user>` needs and
    /// the alternative is making the user type a name the app is already holding a token
    /// for — which is also the name they would most plausibly typo.
    static func login(token: String) async -> String? {
        var request = URLRequest(url: userURL)
        request.httpMethod = "GET"
        api(&request, token: token)
        guard case .answered(let status, let body) = await send(request),
              status == 200,
              let login = fields(body)?["login"] as? String,
              !login.isEmpty else { return nil }
        return login
    }

    // MARK: - plumbing

    private static func fields(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// The message for an error code that is not part of the poll's normal rhythm.
    ///
    /// GitHub's own `error_description` is deliberately ignored for the codes named here.
    /// It says things like "Device flow is disabled for this application", which is true
    /// and useless: it does not say where the switch is. These strings do.
    private static func explain(_ error: String, _ description: String?) -> String {
        switch error {
        case "device_flow_disabled":
            return "This GitHub app registration does not have device flow enabled. Turn on \"Device flow\" in its settings."
        case "incorrect_client_credentials":
            return "GitHub does not recognize this client id. Check \(GitHubApp.infoKey) in Info.plist."
        case "incorrect_device_code":
            return "GitHub no longer recognizes this login attempt. Start again."
        case "unsupported_grant_type":
            return "GitHub refused the device grant. The request was malformed — this is a bug in this app."
        case "expired_token":
            return "That code expired. Start again."
        case "access_denied":
            return "That login was refused on GitHub."
        default:
            if let description, !description.isEmpty { return description }
            return "GitHub said \(error)."
        }
    }

    /// `Accept: application/json` on both `github.com` OAuth endpoints, because the
    /// default there is `application/x-www-form-urlencoded` — a 200 whose body is
    /// `access_token=gho_…&scope=…`, which parses as JSON exactly never and would make
    /// every successful login read as a failure.
    private static func form(url: URL, pairs: [(String, String)]) -> URLRequest {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = pairs.map { name, value in
            let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(name)=\(escaped)"
        }.joined(separator: "&")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(encoded.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The two headers `api.github.com` wants on every call. The version is pinned
    /// because an unpinned REST call follows whatever GitHub defaults to next.
    private static func api(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    }

    /// A reply, or the reason there wasn't one.
    ///
    /// Named rather than a `Result<_, String>` because `Result`'s failure must conform
    /// to `Error`, and the only way to put a bare string there is to conform `String`
    /// itself — a module-wide change to every `throw`, `catch` and `Error`-constrained
    /// generic in the app, bought for one file's convenience.
    private enum Reply {
        case answered(status: Int, body: Data)
        case offline(String)
    }

    /// Ten seconds, the same budget `Omarchy.connectTimeout` gives a box.
    ///
    /// The status is handed back rather than thrown on: every caller here has a
    /// classifier that needs the code and the bytes together, and a 4xx from GitHub is
    /// information, not an error.
    private static func send(_ request: URLRequest) async -> Reply {
        var request = request
        request.timeoutInterval = TimeInterval(Omarchy.connectTimeout)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return .answered(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            return .offline(Workshop.short(error))
        }
    }
}

/// The GitHub account this phone is signed into, if any.
///
/// The token lives in the Keychain and never in `UserDefaults` or in this object's
/// storage: it can add SSH keys to a person's GitHub account, which is the widest blast
/// radius of any credential the app holds. Only the login is published as observable
/// state, because that is all a view needs to say who is signed in.
///
/// `signOut` deletes both entries locally and stops there. Revoking a token through
/// GitHub's API needs the client secret this app deliberately does not have, so the
/// honest thing is to drop it here and let the user revoke it under
/// Settings → Applications if they want it dead everywhere.
@MainActor
@Observable
final class GitHubAccount {
    private(set) var login: String?

    var isSignedIn: Bool { login != nil }

    /// Read the login back at launch. Only the login: the token is fetched at the moment
    /// it is used, so a signed-in session does not keep one in memory for hours.
    func restore() {
        login = Keychain.load(Secret.githubLogin)
    }

    func store(token: String, login: String) {
        Keychain.save(token, as: Secret.githubToken)
        Keychain.save(login, as: Secret.githubLogin)
        self.login = login
    }

    func token() -> String? {
        Keychain.load(Secret.githubToken)
    }

    /// Both entries, always. A login left behind without its token is a screen that says
    /// "signed in as …" and fails every request it offers.
    func signOut() {
        Keychain.delete(Secret.githubToken)
        Keychain.delete(Secret.githubLogin)
        login = nil
    }
}
