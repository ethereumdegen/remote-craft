import Foundation

/// Seed the app from launch arguments, so any screen can be reached in one command.
///
/// ```
/// xcrun simctl launch booted com.remotecraft.ios \
///     -RCHost 100.64.0.1 -RCUser andrew -RCPort 22 \
///     -RCKeyFile /tmp/id_ed25519 -RCOpen shell
/// ```
///
/// This exists because an unseen screen is where defects live: a view that can only be
/// reached by typing an address, pasting a key and tapping connect is a view nobody checks
/// on a tired afternoon, and the SSH path in particular cannot be exercised by a unit test
/// at all. `UserDefaults` is used rather than a bespoke parser because `-Key value` pairs
/// on an iOS launch command line land there automatically.
///
/// DEBUG only, and deliberately so: these arguments write a private key into the Keychain
/// and trust a host address without anyone confirming either.
#if DEBUG
@MainActor
enum Launch {
    static func seed(hosts: HostBook, keys: KeyRing, navigator: Navigator) {
        let defaults = UserDefaults.standard
        func value(_ name: String) -> String? {
            guard let text = defaults.string(forKey: name)?.trimmingCharacters(in: .whitespaces),
                  !text.isEmpty
            else { return nil }
            return text
        }

        var keyID = ""
        // A file rather than the key itself: a PEM on a command line would be one line
        // with literal "\n" in it, and the parser would be debugging the shell instead.
        if let path = value("RCKeyFile"),
           let pem = try? String(contentsOfFile: path, encoding: .utf8) {
            let name = value("RCKeyName") ?? "launch key"
            if let existing = keys.keys.first(where: { $0.name == name }) {
                keyID = existing.id
            } else if let record = keys.importKey(named: name, pem: pem, passphrase: "") {
                keyID = record.id
            }
        }
        // `-RCEnclaveKey YES` attaches the on-device Secure Enclave key instead,
        // generating one if this is a clean install. That is the path a real Omarchy
        // user takes, so it is the one worth being able to exercise without tapping.
        if defaults.bool(forKey: "RCEnclaveKey") {
            if let existing = keys.keys.first(where: \.isEnclave) {
                keyID = existing.id
            } else if let record = keys.generateEnclaveKey(named: "launch enclave key") {
                keyID = record.id
            }
        }

        if let address = value("RCHost") {
            let name = value("RCName") ?? "launch"
            var host = hosts.hosts.first { $0.name == name } ?? SSHHost()
            host.name = name
            host.address = address
            host.fallbackAddress = value("RCFallback") ?? ""
            host.port = Int(value("RCPort") ?? "") ?? 22
            host.username = value("RCUser") ?? host.username
            host.agentPort = Int(value("RCAgentPort") ?? "") ?? host.agentPort
            if !keyID.isEmpty { host.keyID = keyID }
            hosts.save(host)
            hosts.selectedID = host.id
            if let token = value("RCPodKey") {
                hosts.setToken(token, for: host)
            }
        }

        if let tab = value("RCOpen") {
            switch tab {
            case "shell", "terminal": navigator.tab = .terminal
            case "agent": navigator.tab = .agent
            case "hosts": navigator.tab = .hosts
            case "keys": navigator.tab = .keys
            case "settings": navigator.tab = .settings
            // The enrollment sheet is the screen this app is built around and the one
            // that takes the most taps to reach by hand — Keys, then a button, then a
            // branch — so it gets a name of its own here.
            case "enroll":
                navigator.tab = .keys
                navigator.enrolling = true
            default: break
            }
        }
    }
}
#endif
