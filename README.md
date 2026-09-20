# remote-craft

A thin client for a box you are not sitting at.

Two things, one product: an SSH terminal onto an [Omarchy](https://omarchy.org) machine
over a tailnet, and a chat surface onto whatever coding agent is running there.
Ships as a **ratatui TUI** for Linux and macOS (`rcraft`) and a **native SwiftUI iOS app**
(`ios/`), both speaking the same three protocols to the same boxes.

```
  iPhone ──┐                            ┌── omp acp ······ ACP JSON-RPC over an SSH exec channel
           ├── Tailscale ── sshd ───────┼── neo ask ······ one process per prompt, JSON on stdout
  laptop ──┘         └─ :3002 ──────────┴── metalcraft-agent ··· HTTP + SSE, Bearer
```

## Why SSH carries almost everything

This is the part worth understanding before reading the code.

Of the three agents worth talking to, **only one has a network API**:

| Agent | Network surface | How remote-craft reaches it |
| --- | --- | --- |
| **OMP** (`@oh-my-pi/pi-coding-agent`) | none — `--mode rpc` and `acp` are **stdio only**, no bind address, no port, no auth | SSH **exec** channel running `omp acp`, speaking ACP JSON-RPC 2.0 newline-delimited over that channel |
| **starkbot-neo** | none at all — no server, no daemon, no socket | SSH exec, `neo ask "<prompt>"`, one process per prompt, parse the JSON it prints |
| **metalcraft-agent** | real: axum on `0.0.0.0:3002`, `/api/v1/*`, Bearer auth, SSE streaming | plain HTTP straight over the tailnet |

So SSH is not a fallback here, it is the transport. The same connection that gives you a
shell gives you the agent, which is why a host and an agent are separate rows on the same
screen and why there is no separate "agent server" to install.

Tailscale is **not linked into either client**. Both rely on the system Tailscale client and
dial `100.x` addresses or MagicDNS names like any other host. Embedding `tsnet` would drag a
Go runtime into the process and create a second node per install; `tailscale-rs` is still a
DERP-only preview with no DNS. Every host therefore stores **both** its MagicDNS name and a
pinned `100.x` fallback, because MagicDNS resolution inside a third-party iOS app is the
flakiest link in the chain and a pinned address turns a mysterious hang into a connection.

## Requirements

- Rust 1.91+ (edition 2024) for the TUI.
- Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the iOS app.
- On the remote box: `sshd` with an **ed25519 or ECDSA host key** (the iOS SSH stack refuses
  RSA host keys), plus whichever agents you want — `omp`, `neo`, or `metalcraft-daemon --api`.

## Getting into an Omarchy box

Omarchy ships with **SSH off and port 22 closed** — `ufw default deny incoming`, and the
only hole is 53317 for LocalSend. Nothing will connect until someone turns it on, so this
is the first thing to get right and the first error either client explains.

Omarchy has exactly one remote-in feature, `omarchy-setup-security-sshd`, at
`Super + Space` → **Setup → Security → SSHD**. It installs openssh, enables `sshd`, opens
port 22 rate-limited, authorizes a key, and then writes
`/etc/ssh/sshd_config.d/10-omarchy-hardening.conf` turning password auth off. Two
non-interactive forms, both of which do the whole server side in one command:

```bash
# authorize one specific key — what the iOS app's Secure Enclave key needs, and the
# only non-interactive form every released Omarchy understands
omarchy-setup-security-sshd --key="ecdsa-sha2-nistp256 AAAA… remote-craft@iPhone"

# authorize every public key on a GitHub account — the "git keys" route.
# --gh-keys was merged upstream on 2026-08-16, *after* the v4.0.4 tag, so a box on a
# released Omarchy answers `unknown option` and exit 2 without touching anything;
# the fallback drops into the same script's prompts, where "Grab key from GitHub"
# plus the username does exactly what the flag would have.
omarchy-setup-security-sshd --gh-keys <github-username> || omarchy-setup-security-sshd
```

The second is literally `curl -fsSL https://github.com/<user>.keys` into
`~/.ssh/authorized_keys`. Only GitHub keys of type **authentication** appear at that URL;
a *signing* key is silently absent, which is a confusing five minutes unless you know.
Fix with `gh ssh-key add ~/.ssh/id_ed25519.pub --type authentication`.

The iOS app signs in to GitHub and publishes its own Enclave key through
`POST /user/keys`, so it always takes the short second form and never hits the
signing-key trap — see `ios/README.md`. The TUI does neither: it runs on a machine that
already has `ssh`, `gh` and a shell, where the first form is one paste.

Note what neither form is: a subscription. Omarchy `curl`s that URL once, when the script
runs, so a key published afterwards is invisible to a box that already ran it. Every key
after the first is an append to `~/.ssh/authorized_keys` over a connection that already
works — which is what the iOS app's *authorize over the live session* does, and what
`ssh box 'cat >> ~/.ssh/authorized_keys'` does here.

Worth knowing, because each one has its own failure mode:

- **Omarchy never generates an SSH keypair.** Its install only sets `git config --global
  user.name/user.email`. If you expected an `~/.ssh/id_ed25519` to already exist, it does not.
- **Password auth is off** on every current box, forcibly. Neither client implements a
  password path; they detect it and say so.
- **Host keys are stock Arch** (`ssh-keygen -A`), so ed25519 is always present. That matters
  because Apple's swift-nio-ssh supports no RSA at all, in either direction.
- **`ufw limit 22/tcp` bans an address after 6 connections in 30 seconds.** Both clients cap
  reconnects below that; a client that retries eagerly locks itself out.
- **Finding the box:** `tailscale ip -4`, `tailscale status --json`, or the Tailscale bar
  panel (`c` copies the peer IP, `n` the name, `d` the DNS name). On the same Wi-Fi,
  `omarchy.local` works — Omarchy enables avahi and `mdns_minimal`.
- Tailscale runs `tailscale up --accept-routes` and **not** `--ssh`, so this is ordinary SSH
  over the tailnet, not Tailscale SSH.

## Quick start

```bash
cargo install --path .          # or: cargo run
rcraft                          # opens the connection screen
rcraft --host box               # connect straight to a host
rcraft --agent omp              # open an agent immediately
rcraft hosts                    # list what is configured, and where each secret lives
```

## Configuration

`~/.config/remote-craft/config.json` — the non-secret half. `$REMOTE_CRAFT_CONFIG_DIR` and
`$XDG_CONFIG_HOME` override the location. `~/.config` is used on macOS too, on purpose: a
laptop and a desktop should be able to share this file without disagreeing about where it lives.

```json
{
  "default_host": "box",
  "hosts": {
    "box": {
      "addr": "box.tailnet.ts.net",
      "fallback_addr": "100.64.0.1",
      "port": 22,
      "user": "andrew",
      "identity": "~/.ssh/id_ed25519"
    }
  },
  "agents": {
    "omp":  { "kind": "acp",      "host": "box", "cwd": "/home/andrew/code" },
    "neo":  { "kind": "exec",     "host": "box" },
    "pod":  { "kind": "workshop", "url":  "http://box.tailnet.ts.net:3002" }
  }
}
```

`identity` is optional — leave it out and `$SSH_AUTH_SOCK` is used instead, which is the
right default on a machine that already runs an agent.

### Secrets

Never in `config.json`. The OS keyring first, a `0600 credentials.json` second (an Omarchy
box is exactly the kind of headless machine where no keyring daemon is running, and failing
there would make the tool useless on half its targets). `rcraft hosts` always reports which
store answered.

```bash
printf %s "$WORKSHOP_API_KEY" | rcraft token pod            # metalcraft-agent bearer
printf %s "$PASSPHRASE"       | rcraft passphrase ~/.ssh/id_ed25519
rcraft forget agent:pod
```

Reading from stdin rather than prompting is deliberate: there is no hidden-input prompt here,
and a secret typed at a shell ends up in the history file.

## Keyboard reference

| Anywhere | |
| --- | --- |
| `tab` | cycle hosts → shell → agent → log |
| `?` | keys |
| `q` | quit |

| Hosts | |
| --- | --- |
| `j` / `k`, `↑` / `↓` | move |
| `enter` | connect a host, or open an agent |
| `g` / `G` | first / last |
| `r` | reload `config.json` from disk |

| Shell | |
| --- | --- |
| `i` / `enter` | send keystrokes to the remote PTY |
| `ctrl+a d` | stop sending, leave the shell open |
| `ctrl+a a` | send a literal `ctrl+a` |
| `ctrl+a tab` | switch pane without detaching |
| `x` | close the shell |

The prefix is `ctrl+a`, borrowed from screen and tmux, because once every keystroke belongs
to the remote side there has to be one that still means "stop".

| Agent | |
| --- | --- |
| `i` | write a prompt |
| `enter` / `alt+enter` | send / newline |
| `s`, `ctrl+c` | interrupt the running turn |
| `1`–`9` | pick an option the agent offered |
| `j` / `k` / `G` | scroll, jump back to following |

A permission request takes over input until it is answered, including `esc`, which answers
*deny*. That is not a modal being rude: an unanswered ACP `session/request_permission` hangs
the remote turn forever.

## Source

```
src/
  main.rs       clap, terminal lifecycle, the blocking event loop
  app.rs        all state, in one struct, owned by the draw loop
  ui.rs         every pixel, as free functions over &App
  event.rs      the one vocabulary workers and the UI share
  config.rs     hosts and agents; no secrets, ever
  creds.rs      keyring first, 0600 file second
  ssh.rs        russh: connect, PTY shell, exec channels
  term.rs       vt100 state and keystroke encoding
  agent.rs      backend dispatch + the exec (starkbot-neo) adapter
  acp.rs        ACP JSON-RPC over an SSH exec channel (OMP)
  workshop.rs   metalcraft-agent HTTP + SSE
  editor.rs     the composer's text model
ios/            the SwiftUI app — see ios/README.md
```

The draw loop is synchronous and owns all state; transports are async and own none. Everything
crossing that line is a `Msg` on a `std::sync::mpsc` channel drained once per frame, and
everything going the other way is a command on a `tokio` unbounded channel. There is no shared
lock and nothing awaits inside `draw`, which is why a wedged SSH connection still leaves the
interface responsive enough to quit.

## Development

```bash
cargo fmt --check && cargo check && cargo test
```

No `tracing`, no log file. Diagnostics land in the bounded in-memory ring behind the **LOG**
pane and in the status bar, because a TUI that writes its own debugging to stdout is fighting
itself for the screen.

## License

MIT
