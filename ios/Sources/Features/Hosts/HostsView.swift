import SwiftUI

/// The boxes. Pick one — the terminal and the agent both follow the selection.
struct HostsView: View {
    @Environment(HostBook.self) private var hosts
    @Environment(KeyRing.self) private var keys
    @Environment(Navigator.self) private var navigator

    @State private var editing: SSHHost?
    @State private var enrolling = false

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                if hosts.hosts.isEmpty {
                    EmptyState(icon: "server.rack",
                               title: "No hosts",
                               detail: "A stock Omarchy box has SSH switched off and port 22 closed. One command on the box turns it on and authorizes this phone — start there, then add the box's address.",
                               action: ("connect this phone", { enrolling = true }),
                               secondary: ("add a host", { editing = SSHHost() }))
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(hosts.hosts) { host in
                                row(host)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle("hosts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = SSHHost() } label: { Image(systemName: "plus") }
                        .tint(Theme.accent)
                }
            }
            .sheet(item: $editing) { host in
                HostEditor(host: host)
            }
            .sheet(isPresented: $enrolling) { EnrollView() }
        }
        .tint(Theme.accent)
    }

    private func row(_ host: SSHHost) -> some View {
        let isSelected = hosts.selected?.id == host.id
        let key = keys.keyed(host.keyID)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(host.displayName)
                    .font(Theme.mono(14, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.ink)
                Spacer()
                if isSelected { Chip(text: "active", tint: Theme.accent) }
            }
            Text(host.label)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
            HStack(spacing: 6) {
                if host.fallbackAddress.isEmpty {
                    Chip(text: "no fallback", tint: Theme.alarm)
                } else {
                    Chip(text: "fallback \(host.fallbackAddress)")
                }
                Chip(text: key?.name ?? "no key", tint: key == nil ? Theme.alarm : Theme.dim)
                Chip(text: "agent :\(host.agentPort)")
            }
            HStack(spacing: 10) {
                Button("use") {
                    hosts.selectedID = host.id
                    navigator.tab = .terminal
                }
                .buttonStyle(CraftButton())
                Button("edit") { editing = host }
                    .buttonStyle(CraftButton(tint: Theme.dim))
                Spacer()
                Button("delete") { hosts.delete(host) }
                    .buttonStyle(CraftButton(tint: Theme.alarm))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

/// Add or change a box.
///
/// The address fields get most of the screen because picking an address is the decision
/// this app most often gets made badly. There are exactly three ways to reach an Omarchy
/// box and each one fails differently, so each one is named, pre-filled where it can be,
/// and paired with the literal command that prints it on the box.
struct HostEditor: View {
    @Environment(HostBook.self) private var hosts
    @Environment(KeyRing.self) private var keys
    @Environment(\.dismiss) private var dismiss

    @State private var draft: SSHHost
    @State private var port: String
    @State private var agentPort: String
    @State private var token: String
    @State private var showAdvanced = false
    private let isNew: Bool

    /// A brand-new host starts at `omarchy.local`. Omarchy's default hostname is
    /// `omarchy` and it enables avahi-daemon, so that name resolves on the LAN of a box
    /// nobody has configured yet — which is exactly the box someone is adding here.
    init(host: SSHHost) {
        var seeded = host
        let isNew = host.address.isEmpty && host.username.isEmpty
        if isNew { seeded.address = "omarchy.local" }
        _draft = State(initialValue: seeded)
        _port = State(initialValue: String(host.port))
        _agentPort = State(initialValue: String(host.agentPort))
        _token = State(initialValue: Keychain.load(Secret.agentToken(host.id.uuidString)) ?? "")
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        CraftField(label: "name", text: $draft.name, placeholder: "omarchy")
                        CraftField(label: "address", text: $draft.address,
                                   placeholder: "omarchy.local", keyboard: .URL)
                        addressSources
                        VStack(alignment: .leading, spacing: 6) {
                            CraftField(label: "fallback address", text: $draft.fallbackAddress,
                                       placeholder: "100.101.102.103", keyboard: .numbersAndPunctuation)
                            Text("The address that rescues a failing MagicDNS lookup. Inside a third-party app the tailnet name sometimes does not resolve at all; every connection tries the name first and this second, so filling it in is the difference between a flaky app and a working one.")
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.faint)
                        }
                        CraftField(label: "username", text: $draft.username, placeholder: "andrew")
                        advanced
                        VStack(alignment: .leading, spacing: 6) {
                            Eyebrow(text: "key")
                            if keys.keys.isEmpty {
                                Text("No keys yet. Generate one in the Keys tab, then paste its public line into ~/.ssh/authorized_keys on the box.")
                                    .font(Theme.mono(11))
                                    .foregroundStyle(Theme.dim)
                            } else {
                                ForEach(keys.keys) { key in
                                    Button {
                                        draft.keyID = key.id
                                    } label: {
                                        HStack {
                                            Image(systemName: draft.keyID == key.id
                                                  ? "largecircle.fill.circle" : "circle")
                                            Text(key.name).font(Theme.mono(12))
                                            Spacer()
                                            Chip(text: key.isEnclave ? "enclave" : key.algorithm)
                                        }
                                        .foregroundStyle(draft.keyID == key.id ? Theme.accent : Theme.dim)
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Eyebrow(text: "agent")
                            CraftField(label: "preset", text: $draft.agentPreset,
                                       placeholder: "general-agent")
                            VStack(alignment: .leading, spacing: 4) {
                                Eyebrow(text: "workshop api key")
                                SecureField("bearer token", text: $token)
                                    .font(Theme.mono(12))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(8)
                                    .background(Theme.raised)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
                            }
                            Text("Sent as `Authorization: Bearer` to metalcraft-agent on this box. Stored in the Keychain, never in preferences.")
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.faint)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(isNew ? "new host" : draft.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }.tint(Theme.dim)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") { save() }
                        .tint(Theme.accent)
                        .disabled(!draft.isUsable)
                }
            }
        }
        .tint(Theme.accent)
    }

    /// The three ways to reach an Omarchy box, with the command that prints each one.
    ///
    /// They are not interchangeable. MagicDNS reaches the box from anywhere but depends
    /// on Tailscale being up on the phone; the `100.x` address reaches it from anywhere
    /// and cannot fail to resolve; `.local` needs nothing but the same Wi-Fi, and is the
    /// only one that works on a box where Tailscale has not been installed yet.
    private var addressSources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "where to get an address")
            source("magicdns name",
                   "omarchy, or omarchy.tailnet.ts.net — works from anywhere, needs Tailscale connected on this phone.",
                   Omarchy.tailscaleStatus)
            source("100.x tailnet address",
                   "The pinned fallback below. Same encrypted path, no name to resolve.",
                   Omarchy.tailscaleAddress)
            source("<hostname>.local",
                   "Same Wi-Fi only. Omarchy enables avahi and names the box omarchy, so omarchy.local is the default and needs no Tailscale at all.",
                   Omarchy.hostnameCommand)
            Text("In Omarchy's Tailscale bar panel: c copies a peer's IP, n its name, d its DNS name.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func source(_ title: String, _ detail: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.mono(11, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.dim)
            CommandBlock(command: command, caption: "on the box")
        }
    }

    /// Port 22 and the agent port, folded away. Omarchy's SSHD setup opens 22 and only
    /// 22, so a port field on the first screen invites someone to change a number that
    /// has exactly one correct value.
    ///
    /// Hand-rolled rather than a `DisclosureGroup` because that control's tap target is
    /// its label and its chevron with dead space between them, and this label is a 10pt
    /// eyebrow — a row nobody can reliably hit is worse than no row.
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showAdvanced.toggle()
            } label: {
                HStack {
                    Eyebrow(text: "advanced")
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.faint)
                }
                .contentShape(Rectangle())
            }
            if showAdvanced {
                HStack(spacing: 12) {
                    CraftField(label: "ssh port", text: $port, keyboard: .numberPad)
                    CraftField(label: "agent port", text: $agentPort, keyboard: .numberPad)
                }
            }
        }
    }

    private func save() {
        draft.port = Int(port) ?? 22
        draft.agentPort = Int(agentPort) ?? 3002
        if draft.agentPreset.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.agentPreset = "general-agent"
        }
        hosts.save(draft)
        hosts.setToken(token.trimmingCharacters(in: .whitespacesAndNewlines), for: draft)
        dismiss()
    }
}
