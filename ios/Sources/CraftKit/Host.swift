import Foundation

/// One Omarchy box, as this app needs to reach it.
///
/// The interesting field is `fallbackAddress`. Tailscale's MagicDNS works by answering DNS
/// for `*.ts.net` from the tailnet's own resolver, and a third-party iOS app does not
/// always get that resolver: the search-domain plumbing is per-process in places, a name
/// resolved once can go stale after a network change, and the failure mode is a hostname
/// that resolves on the box and nowhere else. The `100.x` address is a tailnet address
/// too — same encrypted path, same ACLs — it simply skips the part that breaks. So every
/// connection tries the name first (it is what the user typed and what their known_hosts
/// says) and the pinned address second.
///
/// The agent fields live here rather than in a parallel "agents" list because the product
/// is one box: the shell and the coding agent are the same machine reached two ways, and
/// splitting them would mean typing the same address twice and keeping two copies of the
/// fallback in sync.
struct SSHHost: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    /// The MagicDNS name, e.g. `omarchy.tail1234.ts.net`.
    var address: String = ""
    /// The pinned `100.x` tailnet address. Empty when the user has not supplied one.
    var fallbackAddress: String = ""
    var port: Int = 22
    var username: String = ""
    /// `KeyRecord.id`, or empty when no key has been chosen yet.
    var keyID: String = ""
    /// metalcraft-agent's workshop API port. 3002 unless the box runs it elsewhere.
    var agentPort: Int = 3002
    var agentPreset: String = "general-agent"

    /// Addresses to try, in order, deduplicated. Empty when nothing usable is configured.
    func candidates() -> [String] {
        var seen = Set<String>()
        return [address, fallbackAddress]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `andrew@omarchy.ts.net:22`, the one-line identity shown in a status bar.
    var label: String {
        let host = candidates().first ?? "no address"
        return "\(username.isEmpty ? "?" : username)@\(host):\(port)"
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? (candidates().first ?? "new host") : trimmed
    }

    /// Workshop API roots to try, in the same order and for the same reason.
    ///
    /// Plain HTTP: the agent listens on the tailnet, which is already an authenticated
    /// encrypted network, and it ships no certificate a phone would accept. An IPv6 literal
    /// would need brackets; a `100.x` address never is one, and a MagicDNS name never is
    /// either, so the simple interpolation is correct for every address this app accepts.
    func agentBases() -> [URL] {
        candidates().compactMap { URL(string: "http://\($0):\(agentPort)/api/v1") }
    }

    /// Anything less than this and a connection attempt is guaranteed to fail; the editor
    /// refuses to save, rather than the terminal failing later with a worse message.
    var isUsable: Bool {
        !candidates().isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
