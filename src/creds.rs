//! Secrets, kept out of `config.json`.
//!
//! The OS keyring first, a `0600` JSON file second. The fallback is not a
//! compromise for convenience — an Omarchy box reached over SSH is exactly the
//! kind of headless machine where no keyring daemon is running, and failing
//! there would make the tool useless on half its targets. Which store answered
//! is always reported, because "where did my token go" is otherwise unanswerable.

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;

use anyhow::{Context, Result};

const SERVICE: &str = "remote-craft";

/// Which store a value came from or went to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Store {
    Keyring,
    File,
}

impl Store {
    pub fn describe(self) -> &'static str {
        match self {
            Store::Keyring => "the OS keyring",
            Store::File => "credentials.json",
        }
    }
}

fn file() -> PathBuf {
    crate::config::dir().join("credentials.json")
}

fn keyring_disabled() -> bool {
    std::env::var("REMOTE_CRAFT_NO_KEYRING").is_ok_and(|value| !value.is_empty())
}

fn entry(account: &str) -> Result<keyring::Entry> {
    keyring::Entry::new(SERVICE, account).context("opening the OS credential store")
}

/// A corrupt credentials file is treated as empty rather than fatal: losing a
/// cached token is recoverable, refusing to start is not.
fn read_file() -> BTreeMap<String, String> {
    fs::read_to_string(file())
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn write_file(values: &BTreeMap<String, String>) -> Result<()> {
    let dir = crate::config::dir();
    fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    let path = file();
    let temporary = path.with_extension("json.tmp");
    let mut text = serde_json::to_string_pretty(values).context("encoding credentials")?;
    text.push('\n');
    {
        let mut handle = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)
            .with_context(|| format!("creating {}", temporary.display()))?;
        handle
            .write_all(text.as_bytes())
            .with_context(|| format!("writing {}", temporary.display()))?;
    }
    fs::rename(&temporary, &path).with_context(|| format!("replacing {}", path.display()))
}

/// Look up a secret. `None` means "not stored", which is not an error: an
/// agent with no token configured is a normal state.
pub fn get(account: &str) -> Option<(String, Store)> {
    if !keyring_disabled()
        && let Ok(entry) = entry(account)
        && let Ok(secret) = entry.get_password()
    {
        return Some((secret, Store::Keyring));
    }
    read_file()
        .get(account)
        .map(|secret| (secret.clone(), Store::File))
}

pub fn set(account: &str, secret: &str) -> Result<Store> {
    if !keyring_disabled()
        && let Ok(entry) = entry(account)
        && entry.set_password(secret).is_ok()
    {
        return Ok(Store::Keyring);
    }
    let mut values = read_file();
    values.insert(account.to_string(), secret.to_string());
    write_file(&values)?;
    Ok(Store::File)
}

pub fn delete(account: &str) -> Result<()> {
    if !keyring_disabled()
        && let Ok(entry) = entry(account)
    {
        let _ = entry.delete_credential();
    }
    let mut values = read_file();
    if values.remove(account).is_some() {
        write_file(&values)?;
    }
    Ok(())
}

/// Enough of a secret to recognise it, never enough to use it.
pub fn redact(secret: &str) -> String {
    let head: String = secret.chars().take(8).collect();
    if secret.chars().count() <= 8 {
        return "•".repeat(secret.chars().count().max(4));
    }
    format!("{head}… ({} chars)", secret.chars().count())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redaction_never_reveals_the_tail() {
        let secret = "mck_live_0123456789abcdef";
        let shown = redact(secret);
        assert!(!shown.contains("abcdef"));
        assert!(shown.starts_with("mck_live"));
    }

    #[test]
    fn short_secrets_are_replaced_entirely() {
        assert_eq!(redact("abc"), "••••");
        assert!(!redact("abc").contains('a'));
    }
}
