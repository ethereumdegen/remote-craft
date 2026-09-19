import SwiftUI
import UIKit

/// Keys, and the one screen in the app that tells the user to go and do something on the
/// box: a generated key is useless until its public line is in `authorized_keys`.
struct KeysView: View {
    @Environment(KeyRing.self) private var keys
    @Environment(Navigator.self) private var navigator

    @State private var newName = ""
    @State private var importing = false

    var body: some View {
        @Bindable var navigator = navigator
        return NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        enroller
                        generator
                        if let failure = keys.failure {
                            Text(failure)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.alarm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .panel()
                        }
                        if keys.keys.isEmpty {
                            Text("No keys yet.")
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.dim)
                        } else {
                            ForEach(keys.keys) { key in KeyCard(record: key) }
                        }
                    }
                    .padding(12)
                }
            }
            .navigationTitle("keys")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("import") { importing = true }.tint(Theme.accent)
                }
            }
            .sheet(isPresented: $importing) { KeyImporter() }
            .sheet(isPresented: $navigator.enrolling) { EnrollView() }
        }
        .tint(Theme.accent)
    }

    /// The bridge from "I have a key" to "the box trusts it".
    ///
    /// A generated key is inert until it is in `authorized_keys`, and on a stock Omarchy
    /// box it cannot get there over the network at all — sshd is off and port 22 is
    /// closed. This is the one screen where that gap is visible, so this is where the
    /// one command that closes it belongs.
    private var enroller: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "put a key on an omarchy box")
            Text("A stock Omarchy install has SSH switched off and the firewall closed. One command on the box — with \(Omarchy.terminalKeybind) for a terminal — turns sshd on, opens port 22, and authorizes a key. This screen builds that command for you.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
            Button("connect this phone to a box") { navigator.enrolling = true }
                .buttonStyle(CraftButton())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var generator: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "generate on this device")
            Text("A P-256 key made inside the Secure Enclave. The private half never leaves the chip: it cannot be copied off this phone, backed up, or restored onto another device — and for the same reason an existing ed25519 key can never be moved *into* the Enclave. The Enclave does NIST P-256 and nothing else.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
            HStack(spacing: 10) {
                TextField("key name", text: $newName)
                    .font(Theme.mono(12))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(8)
                    .background(Theme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
                Button("generate") {
                    if keys.generateEnclaveKey(named: newName) != nil { newName = "" }
                }
                .buttonStyle(CraftButton())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

/// One key, and the line the box needs.
struct KeyCard: View {
    @Environment(KeyRing.self) private var keys
    let record: KeyRecord

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(record.name)
                    .font(Theme.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Chip(text: record.isEnclave ? "secure enclave" : "imported",
                     tint: record.isEnclave ? Theme.live : Theme.dim)
            }
            Text(record.algorithm)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.faint)

            if record.publicLine.isEmpty {
                Text("The public line for an RSA key is not derivable here — copy it from the `.pub` file next to the key you imported.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.faint)
            } else {
                Text(record.publicLine)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
            }

            HStack(spacing: 10) {
                if !record.publicLine.isEmpty {
                    Button(copied ? "copied" : "copy public line") {
                        UIPasteboard.general.string = record.publicLine
                        copied = true
                    }
                    .buttonStyle(CraftButton(tint: copied ? Theme.live : Theme.accent))
                }
                Spacer()
                Button("delete") { keys.delete(record) }
                    .buttonStyle(CraftButton(tint: Theme.alarm))
            }

            if !record.publicLine.isEmpty {
                // The command, not a sketch of one. The line it replaced told the user to
                // `echo '<paste>' >> ~/.ssh/authorized_keys`, which is not something
                // anybody can run — and on a stock box it would not help anyway, because
                // sshd is off and port 22 is closed until this command turns them on.
                CommandBlock(command: Omarchy.enrollCommand(publicLine: record.publicLine),
                             caption: "authorizes this key and turns SSH on")
                if let fingerprint = OpenSSHWire.fingerprint(ofPublicLine: record.publicLine) {
                    Text(fingerprint)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.faint)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

/// Paste an existing OpenSSH private key.
///
/// The app holds the real bytes for these, which is strictly weaker than the Enclave path
/// and is why that one is offered first. It exists because most people already have a key
/// the box trusts, and telling them to enroll a new one to try an app is a bad trade.
struct KeyImporter: View {
    @Environment(KeyRing.self) private var keys
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var pem = ""
    @State private var passphrase = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        CraftField(label: "name", text: $name, placeholder: "laptop key")
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow(text: "openssh private key")
                            TextEditor(text: $pem)
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.ink)
                                .scrollContentBackground(.hidden)
                                .background(Theme.raised)
                                .frame(height: 220)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
                            Text("ed25519 or RSA, BEGIN and END lines included. ECDSA keys from disk are not supported — generate an Enclave key instead, which is ECDSA done properly.")
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.faint)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow(text: "passphrase")
                            SecureField("blank if the key has none", text: $passphrase)
                                .font(Theme.mono(12))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(8)
                                .background(Theme.raised)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
                        }
                        if let failure = keys.failure {
                            Text(failure)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.alarm)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("import key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }.tint(Theme.dim)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("import") {
                        if keys.importKey(named: name, pem: pem, passphrase: passphrase) != nil {
                            dismiss()
                        }
                    }
                    .tint(Theme.accent)
                    .disabled(pem.isEmpty)
                }
            }
        }
        .tint(Theme.accent)
    }
}
