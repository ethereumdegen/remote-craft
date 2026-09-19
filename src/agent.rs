//! The agent worker: one spawn point, three very different back ends.
//!
//! `app.rs` must never branch on which agent it is talking to. The whole point
//! of this module is that a Spec goes in, an `AgentHandle` comes out, and from
//! then on the UI only speaks `AgentCmd` and only hears `Msg`. Which of the
//! three protocols is underneath — ACP over an SSH exec channel, Workshop's
//! HTTP+SSE, or a one-shot `neo ask` per prompt — is this file's problem.
//!
//! The Exec back end lives here rather than in its own module because there is
//! no protocol to speak of: run a command, read one JSON document, done. What
//! does deserve care is `shell_quote`, which is the single place where text a
//! human typed becomes part of a remote command line.

use anyhow::{Context, Result};
use serde_json::Value;
use tokio::sync::mpsc::{self, UnboundedReceiver};

use crate::config::AgentKind;
use crate::event::{AgentCmd, AgentHandle, Msg, Scope, Ui, fail};
use crate::ssh::SshClient;

/// Everything a worker needs to reach one agent, flattened out of `Config` so
/// the back ends never have to know that a config file exists.
#[derive(Clone)]
pub struct Spec {
    pub name: String,
    pub kind: AgentKind,
    /// Where to SSH for `Acp` and `Exec`. Unused by `Workshop`.
    pub target: Option<crate::ssh::Target>,
    /// Base URL for `Workshop`. Unused by the SSH kinds.
    pub url: Option<String>,
    /// Workshop bearer token.
    pub token: Option<String>,
    pub cwd: Option<String>,
    /// Remote program name (`omp`, `neo`), already defaulted by `Agent::program`.
    pub program: String,
    pub args: Vec<String>,
    pub yolo: bool,
}

/// Hand-written so a bearer token can never reach a log line, a panic message
/// or a `{spec:?}` someone added while debugging. Everything else is verbatim.
impl std::fmt::Debug for Spec {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Spec")
            .field("name", &self.name)
            .field("kind", &self.kind)
            .field("target", &self.target)
            .field("url", &self.url)
            .field("token", &self.token.as_ref().map(|_| "<redacted>"))
            .field("cwd", &self.cwd)
            .field("program", &self.program)
            .field("args", &self.args)
            .field("yolo", &self.yolo)
            .finish()
    }
}

/// Spawn the agent worker on `rt` and return the handle the UI drives it with.
///
/// The worker owns its transport for its whole life; when its back end returns
/// — cleanly or not — the handle simply stops being answered, and a failure is
/// reported once, on the UI's own channel, in the UI's own vocabulary.
pub fn spawn(rt: &tokio::runtime::Handle, spec: Spec, ui: Ui) -> AgentHandle {
    let (tx, rx) = mpsc::unbounded_channel();
    let kind = spec.kind;
    rt.spawn(async move {
        let outcome = match kind {
            AgentKind::Acp => crate::acp::run(spec, ui.clone(), rx).await,
            AgentKind::Workshop => crate::workshop::run(spec, ui.clone(), rx).await,
            AgentKind::Exec => exec(spec, ui.clone(), rx).await,
        };
        // `{:#}` flattens the anyhow chain onto one line: the UI shows log
        // lines, not stack traces, and the context strings already read as a
        // sentence ("connecting to andrew@box:22: connection refused").
        if let Err(error) = outcome {
            fail(&ui, Scope::Agent, format!("{error:#}"));
        }
        let _ = ui.send(Msg::log(Scope::Agent, "agent worker stopped"));
    });
    AgentHandle::new(tx)
}

/// Quote `text` as a single POSIX shell word.
///
/// This is the injection boundary: everything inside the quotes is inert to
/// the remote shell, including `$(…)`, backticks, newlines and semicolons. The
/// only character that can end the quoting is `'` itself, so it is closed,
/// escaped and reopened — `'\''` — which is the one idiom that works in every
/// Bourne-compatible shell.
pub fn shell_quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('\'');
    for ch in text.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

/// Re-run `command` under the account's *login* shell.
///
/// An SSH exec channel gets a non-interactive, non-login shell, whose PATH is
/// whatever sshd hands it — typically `/usr/bin:/bin` and nothing else. Every
/// agent worth running is installed somewhere that only a login shell knows
/// about: `omp` is a bun script under `~/.bun/bin`, and mise, asdf, nvm and
/// rustup all put their shims on PATH from a profile file. Without this wrapper
/// the common case is `bun: command not found` on a box where the binary plainly
/// works when you ssh in and type it.
///
/// `$SHELL` is expanded by the shell sshd already started, so this stays correct
/// for bash, zsh and fish without the client having to guess. Anything a profile
/// prints on stdout is tolerated by both back ends: the ACP reader treats a
/// non-JSON line as noise, and the exec back end scans for the JSON document
/// rather than assuming it starts at byte zero.
pub fn login_shell(command: &str) -> String {
    format!("exec \"${{SHELL:-/bin/sh}}\" -lc {}", shell_quote(command))
}

/// The starkbot-neo back end: no session, no stream, no protocol. One process
/// per prompt, one JSON document on stdout, and an SSH connection that is
/// deliberately kept open between prompts — reconnecting per prompt would add
/// a full handshake to every single message.
async fn exec(spec: Spec, ui: Ui, mut commands: UnboundedReceiver<AgentCmd>) -> Result<()> {
    let target = spec.target.clone().with_context(|| {
        format!(
            "agent `{}` is kind `exec` but has no host; set `host` on it in config.json",
            spec.name
        )
    })?;
    let client = SshClient::connect(&target)
        .await
        .with_context(|| format!("connecting to {} for agent `{}`", target.label(), spec.name))?;
    let _ = ui.send(Msg::AgentConnected {
        agent: spec.name.clone(),
        detail: client.banner(),
    });

    // `neo` takes its arguments verbatim from the config; only the prompt is
    // dynamic, and only the prompt is quoted.
    let mut prefix = spec.program.clone();
    for arg in &spec.args {
        prefix.push(' ');
        prefix.push_str(arg);
    }

    let mut thread: Option<String> = None;
    let mut closing = false;

    // `let … else` rather than `while let`: the loop body borrows `commands`
    // again inside the select, and a `while let` scrutinee temporary would
    // still be holding it.
    loop {
        let Some(cmd) = commands.recv().await else {
            break;
        };
        match cmd {
            AgentCmd::Prompt(text) => {
                let command = login_shell(&format!("{prefix} ask {}", shell_quote(&text)));
                let running = client.run(&command);
                tokio::pin!(running);

                // Racing the command against the command queue is what makes
                // Cancel possible at all: dropping the future drops the russh
                // channel, which is the only kill switch a one-shot has.
                let outcome = loop {
                    tokio::select! {
                        result = &mut running => break Some(result),
                        next = commands.recv() => match next {
                            Some(AgentCmd::Cancel) | None => break None,
                            Some(AgentCmd::Close) => {
                                closing = true;
                                break None;
                            }
                            Some(AgentCmd::Prompt(_)) => {
                                let _ = ui.send(Msg::log(
                                    Scope::Agent,
                                    "dropped a prompt: this agent runs one at a time",
                                ));
                            }
                            // Exec has no permission gate; nothing to answer.
                            Some(AgentCmd::Answer { .. }) => {}
                        },
                    }
                };

                match outcome {
                    None => {
                        let _ = ui.send(Msg::AgentTurnEnd {
                            reason: "interrupted".into(),
                        });
                    }
                    Some(Err(error)) => {
                        fail(
                            &ui,
                            Scope::Agent,
                            format!("running `{}`: {error:#}", spec.program),
                        );
                        let _ = ui.send(Msg::AgentTurnEnd {
                            reason: "failed".into(),
                        });
                    }
                    Some(Ok(output)) => {
                        report(&ui, &spec, &output, &mut thread);
                    }
                }

                if closing {
                    break;
                }
            }
            // Nothing is running between prompts, so these are no-ops rather
            // than errors — the UI is allowed to be a frame behind.
            AgentCmd::Cancel => {}
            AgentCmd::Answer { .. } => {}
            AgentCmd::Close => break,
        }
    }

    client.close().await;
    Ok(())
}

/// Turn one finished `neo ask` into UI messages. Every path ends in an
/// `AgentTurnEnd`, because the composer stays locked until one arrives.
fn report(ui: &Ui, spec: &Spec, output: &crate::ssh::Output, thread: &mut Option<String>) {
    if output.status != 0 {
        let detail = first_meaningful_line(&output.stderr)
            .or_else(|| first_meaningful_line(&output.stdout))
            .unwrap_or_else(|| "no output".to_string());
        fail(
            ui,
            Scope::Agent,
            format!("`{}` exited {}: {detail}", spec.program, output.status),
        );
        let _ = ui.send(Msg::AgentTurnEnd {
            reason: "failed".into(),
        });
        return;
    }

    let Some(value) = extract_json(&output.stdout) else {
        let detail = first_meaningful_line(&output.stderr)
            .or_else(|| first_meaningful_line(&output.stdout))
            .unwrap_or_else(|| "it printed nothing".to_string());
        fail(
            ui,
            Scope::Agent,
            format!(
                "could not read `{}`'s reply as JSON: {detail}; run the same command over ssh to see what it printed",
                spec.program
            ),
        );
        let _ = ui.send(Msg::AgentTurnEnd {
            reason: "failed".into(),
        });
        return;
    };

    // The thread id is the closest thing this back end has to a session, and
    // it only shows up in the first answer.
    if let Some(id) = value.get("thread_id").and_then(Value::as_str)
        && thread.as_deref() != Some(id)
    {
        *thread = Some(id.to_string());
        let _ = ui.send(Msg::AgentSession { id: id.to_string() });
    }

    match value.get("text").and_then(Value::as_str) {
        Some(text) => {
            let _ = ui.send(Msg::AgentReply {
                text: text.to_string(),
                awaiting: false,
                options: Vec::new(),
            });
            let _ = ui.send(Msg::AgentTurnEnd {
                reason: "completed".into(),
            });
        }
        None => {
            fail(
                ui,
                Scope::Agent,
                format!(
                    "`{}` answered with JSON that has no `text` field; check the agent's version",
                    spec.program
                ),
            );
            let _ = ui.send(Msg::AgentTurnEnd {
                reason: "failed".into(),
            });
        }
    }
}

/// Parse stdout as one JSON document, tolerating a banner or a trailing
/// newline around it. Anything a login shell prints on the way in would
/// otherwise turn a perfectly good answer into a failure.
fn extract_json(stdout: &str) -> Option<Value> {
    let trimmed = stdout.trim();
    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        return Some(value);
    }
    let start = trimmed.find('{')?;
    let end = trimmed.rfind('}')?;
    if end <= start {
        return None;
    }
    serde_json::from_str::<Value>(&trimmed[start..=end]).ok()
}

fn first_meaningful_line(text: &str) -> Option<String> {
    text.lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text_is_wrapped_in_single_quotes() {
        assert_eq!(shell_quote("hello world"), "'hello world'");
        assert_eq!(shell_quote(""), "''");
    }

    #[test]
    fn the_login_shell_wrapper_keeps_the_payload_inert() {
        // The inner command is one quoted word, so the outer shell hands it to
        // the login shell whole instead of re-splitting or expanding it.
        assert_eq!(
            login_shell("neo ask 'hi'"),
            r#"exec "${SHELL:-/bin/sh}" -lc 'neo ask '\''hi'\'''"#
        );
    }

    #[test]
    fn a_prompt_cannot_break_out_through_either_shell() {
        // Two layers of quoting, one payload that tries to escape both.
        let inner = format!("neo ask {}", shell_quote("'; touch /tmp/pwned; '"));
        let wire = login_shell(&inner);
        assert!(!wire.contains("; touch /tmp/pwned; '\""));
        // Every literal quote in the payload survives as the escaped idiom.
        assert!(wire.starts_with(r#"exec "${SHELL:-/bin/sh}" -lc '"#));
        assert!(wire.ends_with('\''));
    }

    #[test]
    fn embedded_single_quote_closes_and_reopens() {
        // don't  ->  'don'\''t'
        assert_eq!(shell_quote("don't"), r"'don'\''t'");
        assert_eq!(shell_quote("'"), r"''\'''");
    }

    #[test]
    fn command_substitution_stays_inert() {
        let quoted = shell_quote("$(rm -rf /) `id` ${HOME}; echo pwned");
        assert_eq!(quoted, "'$(rm -rf /) `id` ${HOME}; echo pwned'");
        // Nothing inside the payload can terminate the quoting.
        assert!(!quoted[1..quoted.len() - 1].contains('\''));
    }

    #[test]
    fn a_quote_before_a_substitution_cannot_escape() {
        let quoted = shell_quote("' ; $(id) ; '");
        // Reassembling the way a shell would: every `'\''` is one literal quote
        // and every other segment is literal text.
        assert_eq!(quoted, r"''\'' ; $(id) ; '\'''");
    }

    #[test]
    fn newlines_survive_quoting() {
        assert_eq!(shell_quote("a\nb"), "'a\nb'");
    }

    #[test]
    fn json_is_extracted_through_shell_noise() {
        let value = extract_json("{\"text\":\"hi\"}\n").expect("clean json");
        assert_eq!(value["text"], "hi");

        let noisy = "Welcome to Omarchy\n{\n  \"text\": \"hi\"\n}\n";
        let value = extract_json(noisy).expect("json after a banner");
        assert_eq!(value["text"], "hi");

        assert!(extract_json("command not found").is_none());
        assert!(extract_json("").is_none());
    }
}
