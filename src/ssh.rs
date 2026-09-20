//! SSH, the only transport this client has.
//!
//! Every remote capability in the app funnels through here: the interactive
//! PTY shell, the `omp acp` exec channel the ACP worker speaks JSON-RPC over,
//! and the one-shot `neo ask` invocation. There is no second path, no HTTP
//! fallback for the boxes themselves, and no shelling out to the system `ssh`
//! binary — a subprocess would take the terminal away from ratatui and put the
//! passphrase prompt somewhere the TUI cannot see it.
//!
//! What this module refuses to do:
//!
//! * **Prompt.** There is no console to prompt on while the alternate screen is
//!   up. A passphrase either comes from `creds.rs` or the connection fails with
//!   an error that says how to store one.
//! * **Guess about host keys.** A changed host key is refused outright. An
//!   unknown host is learned once (TOFU, the same bargain as OpenSSH's
//!   `StrictHostKeyChecking=accept-new`), because otherwise the first
//!   connection to every box would be a dead end with no way to say yes.
//! * **Touch the UI.** Workers own no application state; they emit
//!   `crate::event::Msg` and nothing else.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use russh::keys::agent::client::AgentClient;
use russh::keys::{PrivateKeyWithHashAlg, PublicKeyOrCertificate, known_hosts, load_secret_key};
use russh::{Channel, ChannelMsg, Disconnect, Pty, client};
use tokio::sync::mpsc::{UnboundedReceiver, unbounded_channel};

use crate::event::{Msg, Scope, ShellCmd, ShellHandle, Ui, fail};

/// Resolved connection details. Built from `config::Host`, but standalone so
/// the agent modules can carry one around without dragging in the whole
/// `Config`.
#[derive(Debug, Clone)]
pub struct Target {
    pub addr: String,
    pub fallback: Option<String>,
    pub port: u16,
    pub user: String,
    pub identity: Option<PathBuf>,
}

impl Target {
    pub fn from_host(host: &crate::config::Host) -> Target {
        let mut candidates = host.candidates().into_iter();
        // `candidates()` always yields at least the primary address; the
        // `unwrap_or_default` is only here so a future empty vec degrades into
        // a clear "could not reach" error instead of a panic.
        let addr = candidates.next().unwrap_or_default();
        Target {
            addr,
            fallback: candidates.next(),
            port: host.port,
            user: host.user.clone(),
            identity: host.identity.as_deref().map(expand_tilde),
        }
    }

    /// Addresses to try, in order: the MagicDNS name first, the pinned tailnet
    /// IP second. Always at least one.
    pub fn candidates(&self) -> Vec<String> {
        let mut out = vec![self.addr.clone()];
        if let Some(fallback) = &self.fallback
            && fallback != &self.addr
        {
            out.push(fallback.clone());
        }
        out
    }

    /// "andrew@box.tailnet.ts.net:22"
    pub fn label(&self) -> String {
        format!("{}@{}:{}", self.user, self.addr, self.port)
    }
}

/// A `~/…` identity path in `config.json` is a string, not a shell word, so
/// nothing else would ever expand it — and `load_secret_key` would fail
/// looking for a directory literally named `~`.
fn expand_tilde(path: &Path) -> PathBuf {
    let Ok(rest) = path.strip_prefix("~") else {
        return path.to_path_buf();
    };
    match std::env::home_dir() {
        Some(home) => home.join(rest),
        None => path.to_path_buf(),
    }
}

/// The result of a one-shot command. Stdout and stderr stay separate because
/// `neo ask` prints JSON on one and diagnostics on the other; merging them
/// would make the JSON unparseable exactly when something went wrong.
#[derive(Debug, Clone)]
pub struct Output {
    pub stdout: String,
    pub stderr: String,
    pub status: u32,
}

/// Verdict recorded by the host-key check so `connect` can turn russh's
/// generic `UnknownKey` into a sentence a person can act on.
type Verdict = Arc<Mutex<Option<String>>>;

/// Why one candidate address failed, and whether the next one could help.
enum Failure {
    /// We got far enough to have a conversation and the box refused us. The
    /// answer would be the same at any other address for the same machine, so
    /// this ends the search and is reported verbatim.
    Final(anyhow::Error),
    /// We never got that far — DNS, routing, a closed port. Worth trying the
    /// pinned tailnet IP, which is exactly why `fallback` exists.
    Transport(anyhow::Error),
}

/// The russh client handler. It exists for one callback: deciding whether the
/// server is who it says it is.
struct Client {
    host: String,
    port: u16,
    verdict: Verdict,
}

impl client::Handler for Client {
    type Error = russh::Error;

    /// russh's default implementation rejects every key, so this override is
    /// mandatory, not optional.
    ///
    /// The real 0.63 semantics of `check_known_hosts` — read from the source,
    /// not from folklore — are:
    ///
    /// * `Ok(true)`  — a recorded key for this host matched. Trust it.
    /// * `Err(KeyChanged{line})` — a key of the *same algorithm* is recorded
    ///   and it is a different key. This is the mismatch case, the only one
    ///   that must fail hard, and it names the offending line so the user can
    ///   fix `known_hosts`.
    /// * `Ok(false)` — nothing recorded **for this algorithm**. That is only
    ///   an unknown host if the host has no recorded keys at all; if it has
    ///   some under other algorithms, this is a downgrade attempt and is
    ///   refused.
    ///
    /// The file read is synchronous. It is a few kilobytes off local disk once
    /// per connection, which is cheaper than moving it to a blocking pool.
    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        let key = server_public_key.public_key();
        match known_hosts::check_known_hosts(&self.host, self.port, &key) {
            Ok(true) => Ok(true),
            Err(russh::keys::Error::KeyChanged { line }) => {
                self.record(format!(
                    "the host key for {}:{} does not match the one recorded on line {} of ~/.ssh/known_hosts. \
                     Either the box was reinstalled or something is impersonating it — delete that line only if \
                     you know which.",
                    self.host, self.port, line
                ));
                // Refusing here makes russh abort the handshake with
                // `Error::UnknownKey`; `connect` swaps in the message above.
                Ok(false)
            }
            Ok(false) => {
                // `check_known_hosts` matches per algorithm, so a server that
                // offers `ecdsa-sha2-nistp256` against a box pinned as
                // `ssh-ed25519` lands here rather than in `KeyChanged`.
                // Treating that as "unknown" would let anything on the path
                // pick an algorithm we have not pinned, get trusted in silence
                // and append its own known_hosts line — the pin would be
                // decorative. If we hold any key for this host, a new
                // algorithm is a change, not a first sighting.
                match known_hosts::known_host_keys(&self.host, self.port) {
                    Ok(recorded) if !recorded.is_empty() => {
                        let known: Vec<String> = recorded
                            .iter()
                            .map(|(_, key)| key.algorithm().as_str().to_string())
                            .collect();
                        self.record(format!(
                            "{}:{} offered a host key of type {}, but ~/.ssh/known_hosts already pins it as {}. \
                             A host that suddenly changes key type is either reinstalled or impersonated — \
                             remove the recorded line only if you know which.",
                            self.host,
                            self.port,
                            key.algorithm().as_str(),
                            known.join(", ")
                        ));
                        Ok(false)
                    }
                    _ => self.learn(&key),
                }
            }
            // Any other error means known_hosts could not be consulted at all
            // (no home directory, unreadable file). That is the unknown-host
            // case too: try to learn, and accept if we cannot.
            Err(_) => self.learn(&key),
        }
    }
}

impl Client {
    fn record(&self, message: String) {
        if let Ok(mut slot) = self.verdict.lock() {
            *slot = Some(message);
        }
    }

    /// Trust on first use. A failure to persist the key is not a reason to
    /// refuse the connection — it only means the next connection will learn it
    /// again — so it is recorded and swallowed.
    fn learn(&self, key: &russh::keys::PublicKey) -> Result<bool, russh::Error> {
        if let Err(error) = known_hosts::learn_known_hosts(&self.host, self.port, key) {
            self.record(format!(
                "accepted the host key for {}:{} but could not write it to ~/.ssh/known_hosts ({error})",
                self.host, self.port
            ));
        }
        Ok(true)
    }
}

/// An authenticated session. Not `Clone`: it owns the russh handle, and
/// dropping it tears the whole SSH connection down, taking every channel
/// opened from it with it.
pub struct SshClient {
    handle: client::Handle<Client>,
    endpoint: String,
    auth: String,
}

impl SshClient {
    /// Tries every `Target::candidates()` address in order.
    ///
    /// Auth order: the explicit `identity` key file first (its passphrase, if
    /// any, comes from `creds::get("key:<path>")` — there is nowhere to prompt),
    /// then ssh-agent over `$SSH_AUTH_SOCK`, then an error naming both
    /// attempts. Every address that failed is named too: "it hangs" is the
    /// usual MagicDNS symptom and the user needs to see that the pinned
    /// tailnet IP was tried as well.
    pub async fn connect(target: &Target) -> Result<Self> {
        let mut unreachable = Vec::new();
        for addr in target.candidates() {
            match Self::dial(target, &addr).await {
                Ok(client) => return Ok(client),
                // The box answered and said no. Both candidate addresses are
                // the same machine, so dialling the fallback would ask the
                // same question, wait out the same rejection delay, and bury
                // the real answer in a list.
                Err(Failure::Final(error)) => return Err(error),
                Err(Failure::Transport(error)) => unreachable.push(format!("{addr}: {error:#}")),
            }
        }
        // Omarchy ships with sshd disabled and port 22 closed, so "nothing is
        // listening" is the single likeliest first-run answer — likelier than a
        // wrong address. Naming the command that fixes it turns a dead end into
        // one line to paste on the box. `--key=` rather than `--gh-keys`: the
        // latter is unreleased (merged after v4.0.4) and a released box answers
        // an unknown flag with exit 2, while this machine already has the public
        // key the box needs sitting in a file.
        Err(anyhow!(
            "could not reach {} — tried {}. If this is an Omarchy box, SSH ships turned \
             off: run `omarchy-setup-security-sshd --key=\"$(cat ~/.ssh/id_ed25519.pub)\"` \
             on it (or Super+Space → Setup → Security → SSHD). Otherwise check the tailnet \
             and the `port` in config.json",
            target.label(),
            unreachable.join("; ")
        ))
    }

    async fn dial(target: &Target, addr: &str) -> std::result::Result<Self, Failure> {
        let config = Arc::new(client::Config {
            // A shell left open in a background tab must survive; the keepalive
            // is what stops a NAT or Tailscale idle timeout from silently
            // eating the connection.
            keepalive_interval: Some(Duration::from_secs(30)),
            inactivity_timeout: None,
            nodelay: true,
            ..Default::default()
        });

        let verdict: Verdict = Arc::new(Mutex::new(None));
        let handler = Client {
            host: addr.to_string(),
            port: target.port,
            verdict: Arc::clone(&verdict),
        };

        let mut handle = match client::connect(config, (addr, target.port), handler).await {
            Ok(handle) => handle,
            Err(error) => {
                // A host-key refusal surfaces as a generic `UnknownKey`; the
                // handler left the real explanation behind, and it must reach
                // the user whole rather than wrapped in "is the box up?".
                if let Some(message) = verdict.lock().ok().and_then(|slot| slot.clone())
                    && matches!(error, russh::Error::UnknownKey)
                {
                    return Err(Failure::Final(anyhow!(message)));
                }
                return Err(Failure::Transport(
                    anyhow::Error::new(error)
                        .context(format!("connecting to {addr}:{}", target.port)),
                ));
            }
        };

        let auth = Self::authenticate(&mut handle, target)
            .await
            .map_err(Failure::Final)?;
        Ok(SshClient {
            handle,
            endpoint: format!("{}@{addr}:{}", target.user, target.port),
            auth,
        })
    }

    async fn authenticate(handle: &mut client::Handle<Client>, target: &Target) -> Result<String> {
        let mut attempts = Vec::new();

        if let Some(path) = &target.identity {
            match Self::authenticate_key(handle, &target.user, path).await {
                Ok(auth) => return Ok(auth),
                Err(error) => attempts.push(format!("{}: {error:#}", path.display())),
            }
        } else {
            attempts.push("no `identity` is set for this host in config.json".to_string());
        }

        match Self::authenticate_agent(handle, &target.user).await {
            Ok(auth) => return Ok(auth),
            Err(error) => attempts.push(format!("ssh-agent: {error:#}")),
        }

        bail!(
            "{} rejected every credential — {}. Point `identity` at a key the box accepts, or `ssh-add` one to your agent.",
            target.label(),
            attempts.join("; ")
        )
    }

    async fn authenticate_key(
        handle: &mut client::Handle<Client>,
        user: &str,
        path: &Path,
    ) -> Result<String> {
        let account = format!("key:{}", path.display());
        let passphrase = crate::creds::get(&account).map(|(secret, _)| secret);

        let key = match load_secret_key(path, passphrase.as_deref()) {
            Ok(key) => key,
            Err(russh::keys::Error::KeyIsEncrypted) => bail!(
                "the key is passphrase-protected and no passphrase is stored. This client runs full-screen and \
                 cannot prompt — save the passphrase under the credential account `{account}`, then reconnect"
            ),
            Err(error) if passphrase.is_some() => {
                return Err(error).context(
                    "decrypting the key with the stored passphrase — it is probably the wrong one",
                );
            }
            Err(error) => return Err(error).context("reading the private key"),
        };

        let algorithm = key.algorithm();
        let kind = algorithm.as_str().trim_start_matches("ssh-").to_string();
        // Plain `ssh-rsa` means SHA-1, which every current OpenSSH refuses. Ask
        // the server which rsa-sha2-* it advertised and sign with that instead.
        let hash_alg = if algorithm.is_rsa() {
            handle
                .best_supported_rsa_hash()
                .await
                .context("asking the server which RSA signature algorithms it accepts")?
                .flatten()
        } else {
            None
        };

        let result = handle
            .authenticate_publickey(user, PrivateKeyWithHashAlg::new(Arc::new(key), hash_alg))
            .await
            .context("offering the private key")?;
        if !result.success() {
            bail!(
                "the server refused this key for user `{user}` — authorize it with \
                 `omarchy-setup-security-sshd --key=\"$(cat {}.pub)\"` on the box",
                path.display()
            );
        }
        Ok(format!("{kind} key"))
    }

    async fn authenticate_agent(handle: &mut client::Handle<Client>, user: &str) -> Result<String> {
        let mut agent = AgentClient::connect_env()
            .await
            .context("connecting to the ssh-agent named by $SSH_AUTH_SOCK")?;
        let identities = agent
            .request_identities()
            .await
            .context("asking the ssh-agent for its identities")?;
        if identities.is_empty() {
            bail!("the ssh-agent is running but holds no identities — `ssh-add` your key");
        }

        let count = identities.len();
        let mut last = String::from("no identity was accepted");
        for identity in identities {
            let public = identity.public_key().into_owned();
            let algorithm = public.algorithm();
            let hash_alg = if algorithm.is_rsa() {
                handle
                    .best_supported_rsa_hash()
                    .await
                    .context("asking the server which RSA signature algorithms it accepts")?
                    .flatten()
            } else {
                None
            };
            let label = match identity.comment() {
                "" => public.algorithm().as_str().to_string(),
                comment => comment.to_string(),
            };

            // `authenticate_publickey_with` drives the sign-request round trip
            // back through the agent, so the private key never leaves it.
            match handle
                .authenticate_publickey_with(user.to_string(), public, hash_alg, &mut agent)
                .await
            {
                Ok(result) if result.success() => return Ok("ssh-agent".to_string()),
                Ok(_) => last = format!("`{label}` was refused"),
                Err(error) => last = format!("`{label}` failed to sign ({error})"),
            }
        }
        bail!("offered {count} agent identit{} and {last}", plural(count));
    }

    /// Open an interactive login shell on a fresh channel.
    pub async fn shell(&self, cols: u16, rows: u16) -> Result<Channel<client::Msg>> {
        let channel = self
            .handle
            .channel_open_session()
            .await
            .context("opening the shell channel")?;

        // Enough of a sane tty for a real login shell: signals and line editing
        // on, UTF-8 declared (IUTF8) so the remote line editor counts multibyte
        // characters as one, and eight-bit clean (CS8) so it does not strip the
        // high bit off them. russh appends the TTY_OP_END terminator itself.
        let modes = [
            (Pty::VINTR, 3),
            (Pty::VQUIT, 28),
            (Pty::VERASE, 127),
            (Pty::VKILL, 21),
            (Pty::VEOF, 4),
            (Pty::VSUSP, 26),
            (Pty::VWERASE, 23),
            (Pty::VLNEXT, 22),
            (Pty::ISIG, 1),
            (Pty::ICANON, 1),
            (Pty::IEXTEN, 1),
            (Pty::ECHO, 1),
            (Pty::ECHOE, 1),
            (Pty::ECHOK, 1),
            (Pty::ECHOCTL, 1),
            (Pty::ECHOKE, 1),
            (Pty::ICRNL, 1),
            (Pty::IXON, 1),
            (Pty::IMAXBEL, 1),
            (Pty::IUTF8, 1),
            (Pty::OPOST, 1),
            (Pty::ONLCR, 1),
            (Pty::CS8, 1),
            (Pty::TTY_OP_ISPEED, 38400),
            (Pty::TTY_OP_OSPEED, 38400),
        ];

        channel
            .request_pty(
                true,
                "xterm-256color",
                u32::from(cols),
                u32::from(rows),
                0,
                0,
                &modes,
            )
            .await
            .context("requesting a pty — the box may have PermitTTY disabled")?;
        channel
            .request_shell(true)
            .await
            .context("requesting the login shell")?;
        Ok(channel)
    }

    /// Run a program on a fresh channel and hand back the raw channel.
    ///
    /// Deliberately **no** `request_pty`. The ACP worker writes newline
    /// delimited JSON-RPC into this channel's stdin and parses stdout; a pty
    /// would echo every request straight back as if it were a response and
    /// apply line discipline (CR translation, ^C interpretation, an 8 KiB
    /// canonical-mode line limit) to a stream that must survive byte for byte.
    pub async fn exec(&self, command: &str) -> Result<Channel<client::Msg>> {
        let channel = self
            .handle
            .channel_open_session()
            .await
            .context("opening the exec channel")?;
        channel
            .exec(true, command)
            .await
            .with_context(|| format!("starting `{command}` on {}", self.endpoint))?;
        Ok(channel)
    }

    /// One-shot: run, collect stdout and stderr separately, wait for exit.
    /// This is how `neo ask` is invoked — one process per prompt.
    pub async fn run(&self, command: &str) -> Result<Output> {
        let mut channel = self.exec(command).await?;
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let mut status = None;

        while let Some(msg) = channel.wait().await {
            match msg {
                ChannelMsg::Data { data } => stdout.extend_from_slice(&data),
                // ext 1 is SSH_EXTENDED_DATA_STDERR; nothing else is defined,
                // and anything else would not be stderr.
                ChannelMsg::ExtendedData { data, ext: 1 } => stderr.extend_from_slice(&data),
                ChannelMsg::ExitStatus { exit_status } => status = Some(exit_status),
                // OpenSSH usually sends exit-status before EOF, but the order is
                // not guaranteed, so EOF only ends the loop once the status is
                // in hand. Close always ends it.
                ChannelMsg::Eof if status.is_some() => break,
                ChannelMsg::Close => break,
                _ => {}
            }
        }

        Ok(Output {
            stdout: String::from_utf8_lossy(&stdout).into_owned(),
            stderr: String::from_utf8_lossy(&stderr).into_owned(),
            // A channel that closed without a status did not report failure, so
            // treating it as success is the honest reading; callers that care
            // check the payload anyway.
            status: status.unwrap_or(0),
        })
    }

    /// "andrew@box:22" — the address actually connected to, which may be the
    /// fallback rather than the one in `config.json`.
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    /// "andrew@box:22 · ed25519 key" — shown in the status bar.
    pub fn banner(&self) -> String {
        format!("{} · {}", self.endpoint, self.auth)
    }

    pub async fn close(&self) {
        // Best effort: if the peer already went away there is nothing to say
        // and nobody to say it to.
        let _ = self
            .handle
            .disconnect(Disconnect::ByApplication, "", "")
            .await;
    }
}

fn plural(count: usize) -> &'static str {
    if count == 1 { "y" } else { "ies" }
}

/// Spawn the PTY shell worker on `rt`.
///
/// The returned handle is live immediately even though the connection is not:
/// the UI can queue keystrokes against a shell that is still dialling, and a
/// connection that never comes up reports `Msg::Failed` rather than leaving a
/// handle that silently swallows everything.
pub fn spawn_shell(
    rt: &tokio::runtime::Handle,
    target: Target,
    cols: u16,
    rows: u16,
    ui: Ui,
) -> ShellHandle {
    let (tx, rx) = unbounded_channel();
    rt.spawn(async move {
        if let Err(error) = shell_worker(target, cols, rows, &ui, rx).await {
            fail(&ui, Scope::Shell, format!("{error:#}"));
            // Without this the UI would keep a handle to a shell that never
            // existed and show it as connecting forever.
            let _ = ui.send(Msg::ShellClosed {
                reason: "the shell never opened".to_string(),
            });
        }
    });
    ShellHandle::new(tx)
}

async fn shell_worker(
    target: Target,
    cols: u16,
    rows: u16,
    ui: &Ui,
    commands: UnboundedReceiver<ShellCmd>,
) -> Result<()> {
    let client = SshClient::connect(&target).await?;
    let channel = client
        .shell(cols, rows)
        .await
        .with_context(|| format!("opening a shell on {}", client.endpoint()))?;

    let _ = ui.send(Msg::ShellOpened {
        host: client.endpoint().to_string(),
    });
    let _ = ui.send(Msg::log(Scope::Shell, client.banner()));

    // Reading and writing are split so the select! below can hold a borrow of
    // each half at once; `Channel::wait` takes `&mut self` and would otherwise
    // lock out every write for the lifetime of the loop.
    let (mut reader, writer) = channel.split();

    let reason = match pump(&mut reader, &writer, ui, commands).await {
        Ok(reason) => reason,
        Err(error) => {
            fail(ui, Scope::Shell, format!("{error:#}"));
            "the shell ended after a transport error".to_string()
        }
    };

    let _ = ui.send(Msg::ShellClosed { reason });
    client.close().await;
    Ok(())
}

async fn pump(
    reader: &mut russh::ChannelReadHalf,
    writer: &russh::ChannelWriteHalf<client::Msg>,
    ui: &Ui,
    mut commands: UnboundedReceiver<ShellCmd>,
) -> Result<String> {
    let mut exit = None;

    loop {
        tokio::select! {
            incoming = reader.wait() => {
                let Some(msg) = incoming else {
                    break;
                };
                match msg {
                    // A pty merges stderr into the data stream, but a server
                    // that sends extended data anyway is showing the user
                    // something they need to see, so it goes to the same vt100.
                    ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. } => {
                        let _ = ui.send(Msg::ShellData(data.to_vec()));
                    }
                    ChannelMsg::ExitStatus { exit_status } => {
                        exit = Some(match exit_status {
                            0 => "the remote shell exited".to_string(),
                            code => format!("the remote shell exited with status {code}"),
                        });
                    }
                    ChannelMsg::ExitSignal { signal_name, error_message, .. } => {
                        let detail = if error_message.is_empty() {
                            String::new()
                        } else {
                            format!(" ({error_message})")
                        };
                        exit = Some(format!("the remote shell was killed by {signal_name:?}{detail}"));
                    }
                    ChannelMsg::Eof | ChannelMsg::Close => break,
                    _ => {}
                }
            }
            command = commands.recv() => {
                match command {
                    Some(ShellCmd::Bytes(bytes)) => {
                        writer
                            .data_bytes(bytes)
                            .await
                            .context("writing keystrokes to the remote shell")?;
                    }
                    Some(ShellCmd::Resize { cols, rows }) => {
                        // The local vt100 is resized by app.rs; this is the
                        // other half, telling the remote tty so it reflows and
                        // SIGWINCHes whatever is running.
                        writer
                            .window_change(u32::from(cols), u32::from(rows), 0, 0)
                            .await
                            .context("telling the remote shell about the new window size")?;
                    }
                    // A dropped command channel means the UI is gone; close the
                    // shell rather than leaving a login session on the box.
                    Some(ShellCmd::Close) | None => {
                        let _ = writer.eof().await;
                        let _ = writer.close().await;
                        return Ok("closed".to_string());
                    }
                }
            }
        }
    }

    Ok(exit.unwrap_or_else(|| "the remote shell closed the connection".to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(addr: &str, fallback: Option<&str>) -> crate::config::Host {
        crate::config::Host {
            addr: addr.to_string(),
            fallback_addr: fallback.map(str::to_string),
            port: 22,
            user: "andrew".to_string(),
            identity: None,
        }
    }

    #[test]
    fn the_pinned_tailnet_ip_is_tried_after_magicdns() {
        let target = Target::from_host(&host("box.tailnet.ts.net", Some("100.64.0.1")));
        assert_eq!(
            target.candidates(),
            vec!["box.tailnet.ts.net".to_string(), "100.64.0.1".to_string()]
        );
    }

    #[test]
    fn a_fallback_equal_to_the_primary_is_not_dialled_twice() {
        let target = Target::from_host(&host("100.64.0.1", Some("100.64.0.1")));
        assert_eq!(target.candidates(), vec!["100.64.0.1".to_string()]);
    }

    #[test]
    fn label_is_the_address_a_person_would_type() {
        let mut raw = host("box", None);
        raw.port = 2222;
        assert_eq!(Target::from_host(&raw).label(), "andrew@box:2222");
    }

    #[test]
    fn a_tilde_identity_is_expanded_before_the_key_is_opened() {
        let mut raw = host("box", None);
        raw.identity = Some(PathBuf::from("~/.ssh/id_ed25519"));
        let identity = Target::from_host(&raw).identity.expect("identity");
        assert!(!identity.starts_with("~"));
        assert!(identity.ends_with(".ssh/id_ed25519"));
    }
}
