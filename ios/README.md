# remote-craft (iOS)

A thin client for an Omarchy box over Tailscale: an interactive shell, and a chat screen
driving the coding agent that runs on the same machine. Same product as the `rcraft`
ratatui TUI at the repo root, in SwiftUI.

## Build

The Xcode project is generated. `project.yml` is the source of truth; `RemoteCraft.xcodeproj`
is gitignored and must never be committed.

```sh
cd ios
xcodegen generate
xcodebuild -scheme RemoteCraft -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Run the tests (frame parser, host fallback order, `authorized_keys` encoding, transcript
fold) with:

```sh
xcodebuild -scheme RemoteCraft -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

First build resolves SwiftPM packages and takes a few minutes.

### Two one-time things a fresh machine needs

Both come from SwiftTerm, and both fail the build before a line of this app is compiled.

1. SwiftTerm ships a SwiftPM **build-tool plugin**, and Xcode refuses to run an untrusted
   one from the command line: `Validate plug-in "SwiftTermBuildInfoPlugin"` fails with no
   further explanation. Trust it once —
   `defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES`
   (note Apple's typo in the key) — or pass `-skipPackagePluginValidation` on every build.
2. SwiftTerm has a Metal renderer, so the build needs the Metal toolchain, which Xcode 26
   no longer installs by default: `xcodebuild -downloadComponent MetalToolchain` (≈690 MB).

## Source tree

```
ios/
  project.yml                       XcodeGen source of truth; .xcodeproj is generated
  Sources/
    App/
      RemoteCraftApp.swift          @main; app-scoped stores; scenePhase -> Wake
      RootView.swift                tab shell + Navigator
      Wake.swift                    the wake-recovery generation counter
    CraftKit/                       the wire layer; no SwiftUI below this line
      Diagnosis.swift               failed-connection facts -> named, actionable diagnosis
      Host.swift                    SSHHost, candidate order, agent base URLs
      Keys.swift                    KeyRecord, Secure Enclave + imported keys, SSH auth
      Omarchy.swift                 the box's own commands; GitHub `.keys` outcomes
      PublicKeyLine.swift           OpenSSH public-key wire format + SHA256 fingerprints
      Reconnect.swift               DialSchedule: backoff under Omarchy's ufw rate limit
      SSHSession.swift              Citadel dial with fallback, TOFU host keys, PTY session
      Workshop.swift                metalcraft-agent HTTP client (chats, turn, watch, stop)
      WorkshopEvents.swift          SSE frame types and the `data:` line parser
    Features/
      Agent/{AgentStore,AgentView}.swift
      Enroll/{EnrollStore,EnrollView}.swift
      Hosts/{HostsStore,HostsView}.swift
      Keys/{KeysStore,KeysView}.swift
      Settings/SettingsView.swift
      Terminal/{TerminalStore,TerminalScreen,TerminalSurface,DiagnosisPanel}.swift
    Secrets/Keychain.swift          every credential, `com.remotecraft.ios`, device-only
    UI/{Palettes,Theme,Primitives,QRCode}.swift
  Tests/RemoteCraftTests/
```

Dependencies (SwiftPM, declared in `project.yml`):

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.0 — terminal emulator.
  It ships no usable SwiftUI view (the one in the package is `internal` and `#if DEBUG`),
  so `TerminalSurface.swift` is our own `UIViewRepresentable` around the UIKit
  `TerminalView`.
- [Citadel](https://github.com/orlandos-nl/Citadel) 0.12.1 — SSH client. Note that Citadel
  depends on a **third-party fork** of swift-nio-ssh (`Wellz26/swift-nio-ssh`), not
  Apple's. That is a supply-chain tradeoff accepted for `withPTY`, OpenSSH key parsing and
  a pluggable authentication delegate.

## Connecting to an Omarchy box

**A stock Omarchy install has SSH switched off and port 22 closed** — `ufw default deny
incoming`, with only LocalSend's 53317 open. Nothing connects until someone runs one
command on the box, and that command is the first screen this app offers: *connect this
phone*, reachable from the Hosts empty state, the Keys tab, and any failure that
enrollment would fix.

Omarchy has exactly one remote-in feature, `omarchy-setup-security-sshd`
(`Super + Space` → Setup → Security → SSHD). It installs openssh, enables sshd, runs
`ufw limit 22/tcp`, authorizes a key, and then writes `PasswordAuthentication no` into
`/etc/ssh/sshd_config.d/10-omarchy-hardening.conf`. The app has no password field for
exactly that reason: after enrollment a password would not be accepted anyway.

**This phone's key (the good route).** The enrollment screen generates a Secure Enclave
P-256 key — the private half is created inside the chip and cannot be exported, backed
up, or restored onto another device — and builds the one command that authorizes it,
shown as copyable text and as a QR code:

```sh
omarchy-setup-security-sshd --key="ecdsa-sha2-nistp256 AAAA… remote-craft@iphone"
```

Open a terminal on the box with `Super + Return` and run it.

**GitHub keys (the "git keys" route).** `omarchy-setup-security-sshd --gh-keys <user>`
makes the box fetch `https://github.com/<user>.keys` and authorize everything there. The
app builds that command too, and will fetch the URL first so you know before you walk to
the box whether it will do anything: no such user, no published keys, or N keys are three
different answers. Only keys of type **authentication** are published there —
`gh ssh-key add ~/.ssh/id_ed25519.pub --type authentication --title "iPhone"` fixes a key
that is not. Because that route authorizes a key whose private half lives on another
machine, it ends by importing that private key into the app, which is strictly weaker
than the Enclave key: the app then holds the real private bytes.

Then in Hosts, add the box. There are three ways to address it and they fail differently:

- **MagicDNS name** — `omarchy`, or `omarchy.tail1234.ts.net`. Works from anywhere, needs
  Tailscale connected on the phone. `tailscale status --json` on the box.
- **pinned `100.x` fallback** — the address that rescues a failing MagicDNS lookup, which
  inside a third-party iOS app is the flakiest link in the chain. Every connection tries
  the name first and this second. `tailscale ip -4` on the box. Fill it in.
- **`<hostname>.local`** — same Wi-Fi only, no Tailscale needed. Omarchy enables avahi and
  names the box `omarchy`, so `omarchy.local` is the default for a new host. `hostname`
  on the box.

Omarchy's Tailscale bar panel copies a peer's IP with `c`, its name with `n` and its DNS
name with `d`. Port 22 is behind the editor's *advanced* disclosure, because Omarchy's
setup opens 22 and only 22.

## When it does not connect

The terminal never shows a raw transport error. Every failure is mapped — by
`CraftKit/Diagnosis.swift`, which is a pure function over what was observed and is unit
tested case by case — onto a named diagnosis with a sentence and, where one exists, the
literal command that fixes it: SSH switched off, key not authorized (with this phone's
`SHA256:…` fingerprint to compare), password-only server, RSA-only host key, host key
changed, MagicDNS not resolving, `.local` not resolving, rate-limited by ufw, and a box
that is simply asleep — it is a laptop distro.

Retries back off exponentially and **can never exceed 5 attempts in any 30-second
window**: Omarchy's `ufw limit 22/tcp` bans a source address at 6, and an app that trips
that locks its user out of their own machine. Connect timeout is 10s and the socket
carries Omarchy's own keepalive policy (15s × 3), so a dead link is noticed in ~45s
rather than hanging.

The first connection to an address pins its host key in the Keychain and prints the
fingerprint; check it on the box with
`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`. A later change is refused outright.
Forgetting a pin lives in Settings and costs a typed word, because a one-tap "trust
anyway" is how people click through the attack the pin exists to catch. A reinstall or
Setup → Reset Computer is the benign reason for a key to change.

## Reaching a screen in one command (DEBUG builds)

`Sources/App/Launch.swift` seeds the app from launch arguments, because a screen that
takes six taps to reach is a screen nobody checks:

```sh
xcrun simctl launch booted com.remotecraft.ios \
    -RCHost omarchy.local -RCUser andrew -RCKeyFile /tmp/id_ed25519 \
    -RCOpen shell -RCConnect YES
```

`-RCOpen` takes `shell`, `agent`, `hosts`, `keys`, `settings`, or `enroll` — the last one
opens the enrollment sheet directly.
