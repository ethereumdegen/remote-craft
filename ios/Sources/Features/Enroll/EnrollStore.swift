import Foundation
import Observation

/// The state of the enrollment screen.
///
/// Screen-scoped rather than app-scoped, and held as `@State` by the view rather than
/// injected: nothing here outlives the sheet. The GitHub lookup is the only thing in this
/// app that talks to the public internet, and it is a courtesy check — the answer changes
/// nothing about what the app can do, it only tells the user whether walking to the box
/// and typing `--gh-keys` will accomplish anything.
@MainActor
@Observable
final class Enrollment {
    /// The two ways onto an Omarchy box, both of which end in `omarchy-setup-security-sshd`.
    enum Route: String, CaseIterable, Identifiable {
        /// This phone's Secure Enclave key, authorized with `--key=`.
        case thisPhone
        /// Whatever GitHub publishes for a username, authorized with `--gh-keys`.
        case githubKeys

        var id: String { rawValue }

        var label: String {
            switch self {
            case .thisPhone: return "this phone's key"
            case .githubKeys: return "my github keys"
            }
        }
    }

    var route: Route = .thisPhone
    var username = ""
    private(set) var lookup: GitHubKeys?
    private(set) var checking = false

    /// Ask GitHub what it publishes for this username.
    ///
    /// Three outcomes worth telling apart, and the app names all three: no such user, a
    /// user with nothing published, and N keys. The middle one is the trap — GitHub
    /// answers 200 with an empty body for a user whose only key is a *signing* key, and
    /// `--gh-keys` would then authorize nothing while appearing to succeed.
    func check() async {
        let user = Omarchy.githubUsername(username)
        guard let url = Omarchy.githubKeysURL(username: user) else {
            lookup = .failed("Type a GitHub username first.")
            return
        }
        checking = true
        defer { checking = false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            lookup = GitHubKeys.read(status: status,
                                     body: String(decoding: data, as: UTF8.self),
                                     username: user)
        } catch {
            lookup = .failed("Could not reach github.com: \(error.localizedDescription)")
        }
    }

    func forgetLookup() {
        lookup = nil
    }
}
