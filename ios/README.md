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

### The GitHub sign-in, if you want it

`RC_GITHUB_CLIENT_ID` in `project.yml` is empty in a clean checkout, and the app says so
on screen rather than failing at the first request. Enrollment works without it — the box
command just carries the whole key and the QR code stays. Fill it in, or pass
`xcodebuild RC_GITHUB_CLIENT_ID=Iv1.xxxxxxxx`, to get the short username-shaped command.

**A TestFlight build needs it too, and the release script will not invent one.** Put
`RC_GITHUB_CLIENT_ID=…` in `deploy.env`; `deploy-testflight.sh` passes it to the archive
and warns loudly when it is missing. A build uploaded without it reaches a tester's phone
with the sign-in button explaining that the Info.plist key is empty, which is a whole
round trip through App Store Connect to discover.

A client id is **not** a secret: the device flow exchanges it for a token with no client
secret at all, which is the entire reason this app can talk to GitHub without a backend.

**Register a classic OAuth App**, at <https://github.com/settings/developers> → New OAuth
App. It is the registration this code was written against: the request sends the
`write:public_key` scope, which is exactly what `POST /user/keys` needs there, and its
token does not expire. The form asks for two URLs it will never use for a device flow —
there is no browser redirect in this app, the phone polls — so both are paperwork:

| field | what to put | why |
| --- | --- | --- |
| Application name | `Remote Craft` | shown on the authorization screen |
| Homepage URL | `https://github.com/<you>/remote-craft` | required; GitHub's own docs say to use the repository URL when there is no website |
| Authorization callback URL | the same URL again | required by the form, ignored by the device flow |
| Enable Device Flow | **checked** | unchecked, sign-in returns `device_flow_disabled` |

A **GitHub App** works too and is the more modern registration, but it costs three extra
traps. It ignores OAuth scopes entirely, so `write:public_key` does nothing and the
fine-grained **"Git SSH keys" user permission must be set to write** or publishing
returns 403. Its callback URL is genuinely optional. And *"Expire user authorization
tokens" is on by default* — leave it on and the token dies after eight hours, which this
app cannot survive: it stores one token in the Keychain and has no refresh flow, so
sign-in has to be repeated. Uncheck it, or take the OAuth App.

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
      GitHubAuth.swift              device-flow sign-in; publishes this phone's key
      Keys.swift                    KeyRecord, Secure Enclave + imported keys, SSH auth
      Omarchy.swift                 the box's own commands, and the ones run over SSH
      PublicKeyLine.swift           OpenSSH public-key wire format + SHA256 fingerprints
      Reconnect.swift               DialSchedule: backoff under Omarchy's ufw rate limit
      RemoteEnroll.swift            authorize a key over a connection that already works
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

There is **one key**: a Secure Enclave P-256 key, generated on first use, whose private
half is created inside the chip and cannot be exported, backed up, or restored onto
another device. Everything below is a way of getting some box to trust that one key. The
app no longer offers to import a private key as part of enrollment — it has no reason to
hold private bytes, so it does not.

**The first box costs one command.** Nothing can remove it. `--key=` carries the whole
`authorized_keys` line, so the screen shows it as copyable text *and* as a QR code,
because retyping a hundred characters of base64 across a gap between two machines is how
this step actually fails:

```sh
omarchy-setup-security-sshd --key="ecdsa-sha2-nistp256 AAAA… remote-craft@iphone"
```

**Signing in to GitHub shortens that command to something typeable.** The app publishes
this phone's *Enclave* public key to your account with `POST /user/keys`, which puts it
at `https://github.com/<you>.keys` — the URL Omarchy's script reads. The box command
then becomes:

```sh
omarchy-setup-security-sshd --gh-keys andrew || omarchy-setup-security-sshd
```

The fallback is there because `--gh-keys` is **not in any released Omarchy**: it was
merged upstream on 2026-08-16, after the v4.0.4 tag. A released box parses arguments
before it does anything, so the flag costs one `unknown option` line and exit 2 with
nothing installed, no port opened and no key authorized — and then the bare script runs
and asks "Grab key from GitHub" plus the username, which is the same fetch of the same
URL. One line, either Omarchy.

No QR, no clipboard, no camera. Two things worth knowing before choosing it: `--gh-keys`
authorizes **every** key published on that account, not only this phone's, which is a
wider grant than `--key=`; and because the app creates the key through the API it is
always an *authentication* key, which removes the old trap where a *signing* key is
absent from `/<user>.keys` and `--gh-keys` silently authorizes nothing.

Sign-in is the OAuth **device flow** — the app shows an eight-character code, you enter
it at `github.com/login/device`. Not the web flow: GitHub still requires `client_secret`
at the token endpoint even with PKCE, and a client secret needs a server this app has
deliberately never had. The device flow exchanges a `client_id` alone, which is not a
secret and ships in the bundle.

**Every box after the first costs nothing.** `--gh-keys` is a snapshot: Omarchy `curl`s
the URL once, when the script runs, so a key published afterwards is invisible to a box
that already ran it. Instead, when the terminal is connected, the enrollment screen and
every key card offer *authorize over the live session* — one tap, which appends the line
to `~/.ssh/authorized_keys` over the SSH connection that is already up. SSH multiplexes,
so it opens no new socket and cannot trip the `ufw limit 22/tcp` ban that a second dial
risks. It is idempotent (`grep -qxF` before the append) and it re-applies `700`/`600` on
`~/.ssh` every time, because sshd's `StrictModes` silently ignores a group-writable
`authorized_keys` and that failure looks exactly like an unauthorized key.

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
