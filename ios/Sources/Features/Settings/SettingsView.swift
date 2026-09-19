import SwiftUI

struct SettingsView: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(HostBook.self) private var hosts

    @State private var pins: [String] = []
    /// The pin the user is in the middle of forgetting, if any.
    @State private var unpinning: String?
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        palettes
                        hostKeys
                        about
                    }
                    .padding(12)
                }
            }
            .navigationTitle("settings")
            .onAppear { pins = TrustOnFirstUse.pinnedAddresses() }
        }
        .tint(Theme.accent)
    }

    private var palettes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "theme")
            ForEach(Themes.all) { palette in
                Button {
                    themes.select(palette)
                } label: {
                    HStack(spacing: 10) {
                        HStack(spacing: 3) {
                            ForEach(Array(palette.ansi.prefix(8).enumerated()), id: \.offset) { slot in
                                Rectangle().fill(slot.element).frame(width: 8, height: 14)
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(palette.name)
                                .font(Theme.mono(12, weight: .semibold))
                                .foregroundStyle(themes.palette.id == palette.id ? Theme.accent : Theme.ink)
                            Text(palette.credit)
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.faint)
                        }
                        Spacer()
                        if themes.palette.id == palette.id {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// Forgetting a pinned host key is a real operation, not a debug affordance: a
    /// reinstalled box — or Setup → Reset Computer — presents a new key, and an app that
    /// refuses forever with no way back is an app you delete.
    ///
    /// It is also the one action in this app that can downgrade its own security, so it
    /// costs a typed word. A one-tap "trust anyway" next to a host-key warning is how
    /// people click through the exact attack the pin exists to catch; making the user
    /// type `forget` here, on a screen they had to navigate to, keeps the decision
    /// deliberate and keeps it away from the failure itself.
    private var hostKeys: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "pinned host keys")
            if pins.isEmpty {
                Text("None pinned yet. The first connection to an address records its key; a later change is refused.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.faint)
            } else {
                ForEach(pins, id: \.self) { slot in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(slot)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let line = TrustOnFirstUse.pin(slot: slot),
                           let fingerprint = OpenSSHWire.fingerprint(ofPublicLine: line) {
                            Text(fingerprint)
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.dim)
                                .textSelection(.enabled)
                        }
                        if unpinning == slot {
                            Text("Forgetting this pin means the next key offered for \(slot) is trusted without question. Print the key on the box and check it matches before you do.")
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.alarm)
                            CommandBlock(command: Omarchy.hostKeyCheck, caption: "on the box")
                            HStack(spacing: 10) {
                                TextField("type forget", text: $confirmation)
                                    .font(Theme.mono(11))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(8)
                                    .background(Theme.raised)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
                                Button("confirm") {
                                    TrustOnFirstUse.forget(slot: slot)
                                    unpinning = nil
                                    confirmation = ""
                                    pins = TrustOnFirstUse.pinnedAddresses()
                                }
                                .buttonStyle(CraftButton(tint: Theme.alarm))
                                .disabled(confirmation.lowercased() != "forget")
                                Button("cancel") {
                                    unpinning = nil
                                    confirmation = ""
                                }
                                .buttonStyle(CraftButton(tint: Theme.dim))
                            }
                        } else {
                            Button("forget") {
                                unpinning = slot
                                confirmation = ""
                            }
                            .buttonStyle(CraftButton(tint: Theme.dim))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "about")
            Text("remote-craft \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") — a thin client for an Omarchy box over Tailscale.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
            Text("Terminal by SwiftTerm. SSH by Citadel, which depends on a third-party fork of swift-nio-ssh rather than Apple's — a supply-chain tradeoff taken knowingly for PTY and key-parsing support.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.faint)
            Text("\(hosts.hosts.count) host(s) configured.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}
