//! The non-secret half of the client's state: which boxes exist, which agents
//! live on them, and which key opens the door. No password, token or key
//! material is ever written here — that split is the point, and `creds.rs` owns
//! the other side.
//!
//! JSON, not TOML, and `~/.config/remote-craft` even on macOS: a person with a
//! laptop and a desktop should be able to copy one file between them without
//! the two machines disagreeing about where it lives.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};

/// A machine reachable over SSH — in practice an Omarchy box on a tailnet.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Host {
    /// MagicDNS name or raw address. Tried first.
    pub addr: String,
    /// The `100.x.y.z` address to fall back to. MagicDNS resolution through a
    /// third-party app is the flakiest link in the chain; pinning the tailnet
    /// IP turns a mysterious hang into a working connection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback_addr: Option<String>,
    #[serde(default = "default_port")]
    pub port: u16,
    pub user: String,
    /// Path to an OpenSSH private key. Absent means "ask ssh-agent", which is
    /// the right default on a machine that already has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity: Option<PathBuf>,
}

fn default_port() -> u16 {
    22
}

impl Host {
    /// Addresses to try, in order. Always at least one.
    pub fn candidates(&self) -> Vec<String> {
        let mut out = vec![self.addr.clone()];
        if let Some(fallback) = &self.fallback_addr
            && fallback != &self.addr
        {
            out.push(fallback.clone());
        }
        out
    }
}

/// How to talk to one agent.
///
/// The three variants are not a taxonomy for its own sake — they are the three
/// shapes the agents in this ecosystem actually have. OMP speaks a protocol but
/// only over stdio, so it needs a process on the far end of an SSH exec
/// channel. metalcraft-agent speaks HTTP and can be dialled straight over the
/// tailnet. starkbot-neo speaks nothing at all, so it gets run one prompt at a
/// time and its stdout parsed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentKind {
    /// `omp acp` over an SSH exec channel, ACP JSON-RPC 2.0 over stdio.
    Acp,
    /// metalcraft-agent's Workshop API: HTTP + SSE, Bearer auth.
    Workshop,
    /// One process per prompt over SSH; stdout is the answer.
    Exec,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Agent {
    pub kind: AgentKind,
    /// Which `hosts` entry to run on. Required for `acp` and `exec`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    /// Base URL for `workshop`, e.g. `http://box.tailnet.ts.net:3002`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// Working directory on the remote box.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// Override the remote command. Defaults per kind: `omp` / `neo`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    /// Extra arguments appended verbatim to the remote command line.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    /// Skip the permission gate. Convenient, and exactly as dangerous as it
    /// sounds when the agent has a shell on the other end.
    #[serde(default)]
    pub yolo: bool,
}

impl Agent {
    /// The remote program name, before arguments.
    pub fn program(&self) -> &str {
        match &self.command {
            Some(command) => command,
            None => match self.kind {
                AgentKind::Acp => "omp",
                AgentKind::Exec => "neo",
                AgentKind::Workshop => "",
            },
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Config {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_host: Option<String>,
    #[serde(default)]
    pub hosts: BTreeMap<String, Host>,
    #[serde(default)]
    pub agents: BTreeMap<String, Agent>,
}

impl Config {
    pub fn host(&self, name: &str) -> Result<&Host> {
        self.hosts
            .get(name)
            .ok_or_else(|| anyhow!("no host named “{name}” in {}", path().display()))
    }

    pub fn agent(&self, name: &str) -> Result<&Agent> {
        self.agents
            .get(name)
            .ok_or_else(|| anyhow!("no agent named “{name}” in {}", path().display()))
    }

    /// The host an agent runs on, resolved through the `hosts` table.
    pub fn agent_host(&self, agent: &Agent) -> Result<&Host> {
        let name = agent
            .host
            .as_deref()
            .ok_or_else(|| anyhow!("this agent needs a `host` to run on"))?;
        self.host(name)
    }
}

/// `$REMOTE_CRAFT_CONFIG_DIR` → `$XDG_CONFIG_HOME/remote-craft` →
/// `~/.config/remote-craft`.
pub fn dir() -> PathBuf {
    if let Ok(explicit) = std::env::var("REMOTE_CRAFT_CONFIG_DIR")
        && !explicit.is_empty()
    {
        return PathBuf::from(explicit);
    }
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME")
        && !xdg.is_empty()
    {
        return PathBuf::from(xdg).join("remote-craft");
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".config").join("remote-craft")
}

pub fn path() -> PathBuf {
    dir().join("config.json")
}

/// A missing file is an empty config, not an error — a first run should open
/// the setup screen, not a stack trace. A corrupt file *is* an error, and the
/// message names the file so it can be deleted.
pub fn load() -> Result<Config> {
    let path = path();
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Config::default()),
        Err(error) => return Err(error).with_context(|| format!("reading {}", path.display())),
    };
    serde_json::from_str(&text)
        .with_context(|| format!("parsing {} — delete it to start over", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_file_is_an_empty_config() {
        let dir = std::env::temp_dir().join(format!("rcraft-cfg-{}", std::process::id()));
        unsafe { std::env::set_var("REMOTE_CRAFT_CONFIG_DIR", &dir) };
        let config = load().expect("a missing config file should load as empty");
        assert!(config.hosts.is_empty());
    }

    #[test]
    fn fallback_address_is_offered_after_the_name() {
        let host = Host {
            addr: "box.tailnet.ts.net".into(),
            fallback_addr: Some("100.64.0.1".into()),
            port: 22,
            user: "andrew".into(),
            identity: None,
        };
        assert_eq!(host.candidates(), vec!["box.tailnet.ts.net", "100.64.0.1"]);
    }

    #[test]
    fn a_duplicate_fallback_is_not_tried_twice() {
        let host = Host {
            addr: "100.64.0.1".into(),
            fallback_addr: Some("100.64.0.1".into()),
            port: 22,
            user: "andrew".into(),
            identity: None,
        };
        assert_eq!(host.candidates().len(), 1);
    }
}
