import Foundation
import Observation

/// The boxes this phone knows about.
///
/// Non-secret fields are JSON in `UserDefaults` under `rc.hosts`; the agent bearer for each
/// host is in the Keychain under `Secret.agentToken(id)`. The split is the rule the whole
/// app follows: anything that would let someone else reach the box is Keychain, everything
/// else is a preference.
@MainActor
@Observable
final class HostBook {
    static let hostsKey = "rc.hosts"
    static let selectedKey = "rc.selectedHost"

    private(set) var hosts: [SSHHost] = []
    /// Which host the terminal and agent screens are pointed at.
    var selectedID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedID?.uuidString ?? "", forKey: Self.selectedKey)
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.hostsKey),
           let stored = try? JSONDecoder().decode([SSHHost].self, from: data) {
            hosts = stored
        }
        let saved = UserDefaults.standard.string(forKey: Self.selectedKey) ?? ""
        selectedID = UUID(uuidString: saved) ?? hosts.first?.id
    }

    var selected: SSHHost? {
        guard let selectedID else { return hosts.first }
        return hosts.first { $0.id == selectedID } ?? hosts.first
    }

    /// Insert or update in place. `id` is the identity, so editing a host does not make a
    /// second one and does not orphan the Keychain entry keyed by that id.
    func save(_ host: SSHHost) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        if selectedID == nil { selectedID = host.id }
        flush()
    }

    func delete(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        Keychain.delete(Secret.agentToken(host.id.uuidString))
        for address in host.candidates() {
            TrustOnFirstUse.forget(address: address, port: host.port)
        }
        if selectedID == host.id { selectedID = hosts.first?.id }
        flush()
    }

    func token(for host: SSHHost) -> String {
        Keychain.load(Secret.agentToken(host.id.uuidString)) ?? ""
    }

    func setToken(_ token: String, for host: SSHHost) {
        let account = Secret.agentToken(host.id.uuidString)
        if token.isEmpty {
            Keychain.delete(account)
        } else {
            Keychain.save(token, as: account)
        }
    }

    private func flush() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        UserDefaults.standard.set(data, forKey: Self.hostsKey)
    }
}
