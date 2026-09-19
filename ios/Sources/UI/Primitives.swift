import SwiftUI
import UIKit

/// The connection light. Three states, because those are the three a remote session can
/// truthfully be in: connecting, attached, or gone. A socket that iOS killed while the app
/// was suspended is `.down`, and saying so is the whole point of the wake pass.
enum Liveness: Equatable {
    case idle
    case working
    case up
    case down(String)

    var tint: Color {
        switch self {
        case .idle: return Theme.faint
        case .working: return Theme.accent2
        case .up: return Theme.live
        case .down: return Theme.alarm
        }
    }

    var label: String {
        switch self {
        case .idle: return "idle"
        case .working: return "connecting"
        case .up: return "live"
        case .down(let why): return why
        }
    }
}

struct StatusDot: View {
    let state: Liveness
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: 7, height: 7)
            .opacity(state == .working && pulse ? 0.25 : 1)
            .animation(state == .working
                       ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                       : .default,
                       value: pulse)
            .onAppear { pulse = true }
    }
}

/// The one-line session banner: `andrew@box:22 · live`.
struct StatusBar: View {
    let title: String
    let state: Liveness

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: state)
            Text(title)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            Text(state.label)
                .font(Theme.mono(11))
                .foregroundStyle(state.tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// A bordered capsule for a tag, a port, a key type.
struct Chip: View {
    let text: String
    var tint: Color = Theme.dim

    var body: some View {
        Text(text)
            .font(Theme.mono(10))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 1))
    }
}

struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Theme.faint)
    }
}

/// What a screen shows before it has anything to show, and what it shows when a connection
/// fails. The action is always the next thing to do, never "OK".
struct EmptyState: View {
    let icon: String
    let title: String
    var detail: String = ""
    var action: (label: String, run: () -> Void)?
    /// The other next thing to do, when there genuinely are two. On the hosts screen the
    /// first launch has both: enroll this phone on a box, or type in a box you can
    /// already reach.
    var secondary: (label: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(Theme.faint)
            Text(title)
                .font(Theme.mono(14, weight: .semibold))
                .foregroundStyle(Theme.ink)
            if !detail.isEmpty {
                Text(detail)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            if action != nil || secondary != nil {
                HStack(spacing: 10) {
                    if let action {
                        Button(action.label, action: action.run)
                            .buttonStyle(CraftButton())
                    }
                    if let secondary {
                        Button(secondary.label, action: secondary.run)
                            .buttonStyle(CraftButton(tint: Theme.dim))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CraftButton: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(12, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? Theme.bg : tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(configuration.isPressed ? tint : Theme.raised)
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(tint.opacity(0.6), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
    }
}

/// A text field that does not fight a terminal: monospaced, no autocorrect, no
/// capitalisation. Autocorrect on a hostname field turns `omarchy` into `Anarchy`, which is
/// funny exactly once.
struct CraftField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(text: label)
            TextField(placeholder, text: $text)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .padding(8)
                .background(Theme.raised)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
        }
    }
}

/// A literal command, shown the way the box will see it, with a real copy control.
///
/// The house rule the whole enrollment flow is built on: give the person the command, not
/// a description of the command. A sentence that says "enable sshd and authorise your
/// key" is a sentence the user has to translate; this is the line they paste.
///
/// Selectable as well as copyable, because a user reading a long `--key=` line wants to
/// check the last few characters against what the box printed.
struct CommandBlock: View {
    let command: String
    var caption: String = ""

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(command)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.raised)
                .overlay(RoundedRectangle(cornerRadius: Theme.corner)
                    .stroke(Theme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
            HStack(spacing: 10) {
                Button(copied ? "copied" : "copy") {
                    UIPasteboard.general.string = command
                    copied = true
                }
                .buttonStyle(CraftButton(tint: copied ? Theme.live : Theme.accent))
                if !caption.isEmpty {
                    Text(caption)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .onChange(of: command) { _, _ in copied = false }
    }
}
