import SwiftUI

/// A failed connection, explained.
///
/// The app never shows a raw transport error on this screen. `NIOConnectionError()` and
/// `allAuthenticationOptionsFailed` are true statements that help nobody; what a person
/// standing next to their laptop needs is the name of what went wrong and the line to
/// type. Where a diagnosis has a remedy it is rendered as a copyable command, never as
/// prose describing one.
struct DiagnosisPanel: View {
    let diagnosis: Diagnosis
    let address: String
    /// Whether a further attempt is actually scheduled. Not the same as
    /// `diagnosis.worthRetrying`: the store stops re-dialling a failure it cannot name
    /// after a handful of them, and a caption promising that the app keeps trying while
    /// it has quietly stopped is worse than no caption at all — the user sits and waits.
    var retrying: Bool = false
    var enroll: (() -> Void)?
    var retry: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon)
                            .foregroundStyle(Theme.alarm)
                        Text(diagnosis.title)
                            .font(Theme.mono(14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    if !address.isEmpty {
                        Text(address)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.faint)
                    }
                    Text(diagnosis.explanation)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    if let remedy = diagnosis.remedy {
                        CommandBlock(command: remedy, caption: "run this on the box")
                    }
                    HStack(spacing: 10) {
                        if diagnosis.offersEnrollment, let enroll {
                            Button("connect this phone", action: enroll)
                                .buttonStyle(CraftButton())
                        }
                        if let retry {
                            Button("try again", action: retry)
                                .buttonStyle(CraftButton(tint: Theme.dim))
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel()

                if retrying {
                    Text("The app keeps trying on its own, backing off so it never opens more than \(DialSchedule.connectionsPerWindow) connections in 30 seconds — Omarchy's ufw limit rule bans at 6.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if diagnosis.worthRetrying {
                    Text("The app has stopped retrying on its own — this failure repeated without ever naming itself. Try again above when something has changed.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
    }

    private var icon: String {
        switch diagnosis.cause {
        case .sshdOff: return "bolt.slash"
        case .keyNotAuthorized, .passwordOnly: return "key.slash"
        case .rsaOnlyHostKey, .hostKeyChanged: return "lock.trianglebadge.exclamationmark"
        case .magicDNSUnresolved, .dotLocalUnresolved: return "network.slash"
        case .rateLimited: return "hourglass"
        case .hostAsleep: return "moon.zzz"
        case .unrecognised: return "exclamationmark.triangle"
        }
    }
}
