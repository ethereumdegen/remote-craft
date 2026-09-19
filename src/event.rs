//! The one vocabulary every background worker speaks to the draw loop.
//!
//! The UI thread is synchronous and owns all state; transports are async and
//! own none of it. Everything crossing that line is a `Msg` on a plain
//! `std::sync::mpsc` channel, drained once per frame in `App::tick`. Nothing
//! else — no shared locks, no callbacks into `App`, no `block_on` in `draw`.
//!
//! Commands travel the other way over `tokio::sync::mpsc::UnboundedSender`,
//! whose `send` is callable from a non-async context. That asymmetry is the
//! whole bridge: std channel inbound, tokio channel outbound.

use std::sync::mpsc::Sender;
use tokio::sync::mpsc::UnboundedSender;

/// Which half of the app a failure or a log line belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    Shell,
    Agent,
}

impl Scope {
    pub fn label(self) -> &'static str {
        match self {
            Scope::Shell => "shell",
            Scope::Agent => "agent",
        }
    }
}

/// Lifecycle of one remote tool invocation, as far as the client can tell.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolState {
    Started,
    Completed,
    Failed,
}

/// One line in the bounded in-memory transport log. There is no log file and
/// no `tracing`; when something goes wrong the evidence has to be on screen.
#[derive(Debug, Clone)]
pub struct LogLine {
    pub scope: Scope,
    pub text: String,
}

/// Everything a worker can tell the UI.
#[derive(Debug, Clone)]
pub enum Msg {
    /// The PTY shell is live and the first bytes are on their way.
    ShellOpened { host: String },
    /// Raw bytes from the remote shell, already ordered. Feed straight to vt100.
    ShellData(Vec<u8>),
    /// The shell channel ended. `reason` is human copy, not a code.
    ShellClosed { reason: String },

    /// The agent transport is up. `detail` is a one-line identity banner.
    AgentConnected { agent: String, detail: String },
    /// The agent minted or resumed a session/chat/thread id.
    AgentSession { id: String },
    /// Incremental assistant text. Append; do not insert a separator.
    AgentDelta { text: String },
    /// Incremental reasoning text, rendered dim and collapsible.
    AgentThought { text: String },
    /// A complete assistant message that arrived whole rather than streamed.
    AgentReply {
        text: String,
        awaiting: bool,
        options: Vec<String>,
    },
    /// A tool call changing state. `detail` is a short argument or result digest.
    AgentTool {
        id: String,
        name: String,
        state: ToolState,
        detail: String,
    },
    /// Full replacement of the agent's plan, including the empty list.
    AgentPlan { steps: Vec<String> },
    /// The turn finished. `reason` is `completed`, `interrupted`, `failed`, …
    AgentTurnEnd { reason: String },
    /// The agent wants a human decision before it proceeds. Answering is
    /// mandatory: an unanswered permission request hangs the remote turn.
    AgentPermission {
        id: String,
        prompt: String,
        options: Vec<String>,
    },

    /// A transport or protocol failure, already formatted for a human.
    Failed { scope: Scope, error: String },
    /// A diagnostic worth keeping but not worth interrupting anyone over.
    Log(LogLine),
}

impl Msg {
    pub fn log(scope: Scope, text: impl Into<String>) -> Msg {
        Msg::Log(LogLine {
            scope,
            text: text.into(),
        })
    }
}

/// A worker's end of the bridge.
///
/// It stamps every message with the epoch of the session that created it. A
/// worker outlives the moment the UI stops caring about it — closing a shell
/// only *asks* it to stop, and it still reports its own death afterwards — so
/// without a stamp the dying session's `ShellClosed` arrives after its
/// replacement is installed and tears the replacement down. The UI keeps the
/// current epoch and drops anything older.
#[derive(Debug, Clone)]
pub struct Ui {
    tx: Sender<(u64, Msg)>,
    epoch: u64,
}

impl Ui {
    pub fn new(tx: Sender<(u64, Msg)>, epoch: u64) -> Ui {
        Ui { tx, epoch }
    }

    pub fn send(&self, msg: Msg) -> Result<(), std::sync::mpsc::SendError<(u64, Msg)>> {
        self.tx.send((self.epoch, msg))
    }
}

/// Report a failure and swallow the send error: if the UI is gone, the worker
/// is about to be dropped anyway and there is nobody left to tell.
pub fn fail(ui: &Ui, scope: Scope, error: impl std::fmt::Display) {
    let _ = ui.send(Msg::Failed {
        scope,
        error: error.to_string(),
    });
}

/// What the UI can ask of a live PTY shell.
#[derive(Debug, Clone)]
pub enum ShellCmd {
    /// Already VT-encoded keystroke bytes.
    Bytes(Vec<u8>),
    Resize {
        cols: u16,
        rows: u16,
    },
    Close,
}

/// What the UI can ask of a live agent session.
#[derive(Debug, Clone)]
pub enum AgentCmd {
    Prompt(String),
    /// Interrupt the running turn. The turn is only actually over when an
    /// `AgentTurnEnd` arrives — never unlock the composer on this alone.
    Cancel,
    /// Answer an outstanding `AgentPermission`.
    Answer {
        id: String,
        choice: String,
    },
    Close,
}

/// A live shell. Dropping it does not close the channel; `close` does.
#[derive(Debug, Clone)]
pub struct ShellHandle(UnboundedSender<ShellCmd>);

impl ShellHandle {
    pub fn new(tx: UnboundedSender<ShellCmd>) -> Self {
        Self(tx)
    }

    pub fn bytes(&self, data: Vec<u8>) {
        let _ = self.0.send(ShellCmd::Bytes(data));
    }

    pub fn resize(&self, cols: u16, rows: u16) {
        let _ = self.0.send(ShellCmd::Resize { cols, rows });
    }

    pub fn close(&self) {
        let _ = self.0.send(ShellCmd::Close);
    }
}

/// A live agent session.
#[derive(Debug, Clone)]
pub struct AgentHandle(UnboundedSender<AgentCmd>);

impl AgentHandle {
    pub fn new(tx: UnboundedSender<AgentCmd>) -> Self {
        Self(tx)
    }

    pub fn prompt(&self, text: impl Into<String>) {
        let _ = self.0.send(AgentCmd::Prompt(text.into()));
    }

    pub fn cancel(&self) {
        let _ = self.0.send(AgentCmd::Cancel);
    }

    pub fn answer(&self, id: impl Into<String>, choice: impl Into<String>) {
        let _ = self.0.send(AgentCmd::Answer {
            id: id.into(),
            choice: choice.into(),
        });
    }

    pub fn close(&self) {
        let _ = self.0.send(AgentCmd::Close);
    }
}
