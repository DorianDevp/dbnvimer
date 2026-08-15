//! SSH local forwarding.
//!
//! The daemon keeps the `ssh` child process handle for the lifetime of the
//! tunnel, so shutting one down is `Child::kill` rather than shelling out to
//! `kill(1)` with a possibly recycled pid. That also makes the code work on
//! Windows, where the bundled binary previously had no way to stop a tunnel.

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::net::{TcpListener, TcpStream};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, Debug, Deserialize)]
pub struct SshConfig {
    /// Host name or a `Host` alias from `~/.ssh/config`.
    pub host: String,
    #[serde(default)]
    pub user: Option<String>,
    /// Left unset so `~/.ssh/config` can supply the port.
    #[serde(default)]
    pub port: Option<u16>,
    #[serde(default)]
    pub identity_file: Option<String>,
    #[serde(default = "default_local_host")]
    pub local_host: String,
    #[serde(default)]
    pub local_port: Option<u16>,
    #[serde(default = "default_remote_host")]
    pub remote_host: String,
    #[serde(default)]
    pub remote_port: u16,
    /// Jump host chain, passed straight to `-J`.
    #[serde(default)]
    pub jump: Option<String>,
    /// Refuse to prompt for passwords; fail fast instead of hanging.
    #[serde(default = "default_batch_mode")]
    pub batch_mode: bool,
    #[serde(default = "default_connect_timeout")]
    pub connect_timeout: u16,
    /// Extra `-o Key=Value` options.
    #[serde(default)]
    pub options: Vec<String>,
}

/// Serializable description of a live tunnel. The child process handle is kept
/// out of the wire format but travels with the handle inside the daemon.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct TunnelHandle {
    pub pid: u32,
    pub local_host: String,
    pub local_port: u16,
    pub remote_host: String,
    pub remote_port: u16,
    #[serde(skip)]
    child: Option<Arc<Mutex<Child>>>,
}

const PORT_ATTEMPTS: usize = 5;

pub fn open(config: &SshConfig) -> Result<TunnelHandle> {
    let mut last_error = None;

    // Reserving a port and handing it to ssh is inherently racy, so retry with
    // a fresh port when the bind loses the race.
    for attempt in 0..PORT_ATTEMPTS {
        let local_port = match config.local_port {
            Some(0) | None => free_port(&config.local_host)?,
            Some(port) => port,
        };

        match spawn(config, local_port) {
            Ok(handle) => return Ok(handle),
            Err(error) => {
                let retryable =
                    config.local_port.is_none_or(|port| port == 0) && attempt + 1 < PORT_ATTEMPTS;
                last_error = Some(error);
                if !retryable {
                    break;
                }
            }
        }
    }

    Err(last_error.unwrap_or_else(|| anyhow!("failed to open ssh tunnel")))
}

fn spawn(config: &SshConfig, local_port: u16) -> Result<TunnelHandle> {
    if config.remote_port == 0 {
        return Err(anyhow!("ssh tunnel requires a remote port"));
    }

    let forward = format!(
        "{}:{}:{}:{}",
        config.local_host, local_port, config.remote_host, config.remote_port
    );

    let mut command = Command::new("ssh");
    command
        .arg("-N")
        .arg("-T")
        .arg("-L")
        .arg(&forward)
        .arg("-o")
        .arg("ExitOnForwardFailure=yes")
        .arg("-o")
        .arg("ServerAliveInterval=30")
        .arg("-o")
        .arg("ServerAliveCountMax=3")
        .arg("-o")
        .arg(format!("ConnectTimeout={}", config.connect_timeout));

    if config.batch_mode {
        command.arg("-o").arg("BatchMode=yes");
    }
    if let Some(port) = config.port {
        command.arg("-p").arg(port.to_string());
    }
    if let Some(identity) = &config.identity_file {
        command.arg("-i").arg(identity);
    }
    if let Some(jump) = &config.jump {
        command.arg("-J").arg(jump);
    }
    for option in &config.options {
        command.arg("-o").arg(option);
    }

    let target = match &config.user {
        Some(user) if !user.is_empty() => format!("{user}@{}", config.host),
        _ => config.host.clone(),
    };

    let mut child = command
        .arg(target)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to start ssh; is ssh on PATH?")?;

    // Poll the forwarded port instead of guessing with a fixed sleep.
    let deadline = Instant::now() + Duration::from_secs(u64::from(config.connect_timeout).max(5));
    let pid = child.id();
    loop {
        if let Some(status) = child.try_wait().context("failed to inspect ssh")? {
            let detail = read_stderr(&mut child);
            return Err(anyhow!(
                "ssh tunnel exited with status {status}{}",
                if detail.is_empty() {
                    String::new()
                } else {
                    format!(": {detail}")
                }
            ));
        }

        if TcpStream::connect_timeout(
            &format!("{}:{}", config.local_host, local_port)
                .parse()
                .with_context(|| format!("invalid local address {}", config.local_host))?,
            Duration::from_millis(200),
        )
        .is_ok()
        {
            return Ok(TunnelHandle {
                pid,
                local_host: config.local_host.clone(),
                local_port,
                remote_host: config.remote_host.clone(),
                remote_port: config.remote_port,
                child: Some(Arc::new(Mutex::new(child))),
            });
        }

        if Instant::now() >= deadline {
            let _ = child.kill();
            let detail = read_stderr(&mut child);
            return Err(anyhow!(
                "ssh tunnel did not start listening on {}:{local_port}{}",
                config.local_host,
                if detail.is_empty() {
                    String::new()
                } else {
                    format!(": {detail}")
                }
            ));
        }

        std::thread::sleep(Duration::from_millis(50));
    }
}

/// True when the forwarded port still accepts connections.
pub fn is_alive(handle: &TunnelHandle) -> bool {
    if let Some(child) = &handle.child {
        if let Ok(mut child) = child.lock() {
            if matches!(child.try_wait(), Ok(Some(_))) {
                return false;
            }
        }
    }
    format!("{}:{}", handle.local_host, handle.local_port)
        .parse()
        .ok()
        .and_then(|address| TcpStream::connect_timeout(&address, Duration::from_millis(300)).ok())
        .is_some()
}

pub fn close(handle: &TunnelHandle) -> Result<()> {
    if let Some(child) = &handle.child {
        let mut child = child.lock().unwrap_or_else(|error| error.into_inner());
        let _ = child.kill();
        let _ = child.wait();
        return Ok(());
    }

    // A handle that came back over the wire has no child; fall back to a
    // platform specific kill by pid.
    kill_by_pid(handle.pid)
}

#[cfg(windows)]
fn kill_by_pid(pid: u32) -> Result<()> {
    let status = Command::new("taskkill")
        .args(["/PID", &pid.to_string(), "/F"])
        .status()
        .context("failed to run taskkill")?;
    if status.success() {
        Ok(())
    } else {
        Err(anyhow!("ssh tunnel process {pid} did not stop"))
    }
}

#[cfg(not(windows))]
fn kill_by_pid(pid: u32) -> Result<()> {
    let status = Command::new("kill")
        .arg(pid.to_string())
        .status()
        .context("failed to run kill")?;
    if status.success() {
        Ok(())
    } else {
        Err(anyhow!("ssh tunnel process {pid} did not stop"))
    }
}

fn read_stderr(child: &mut Child) -> String {
    use std::io::Read;
    let Some(stderr) = child.stderr.as_mut() else {
        return String::new();
    };
    let mut buffer = String::new();
    let _ = stderr.read_to_string(&mut buffer);
    buffer
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect::<Vec<_>>()
        .join("; ")
}

fn free_port(host: &str) -> Result<u16> {
    let listener = TcpListener::bind((host, 0)).context("failed to reserve a local tunnel port")?;
    Ok(listener.local_addr()?.port())
}

fn default_local_host() -> String {
    "127.0.0.1".to_string()
}

fn default_remote_host() -> String {
    "127.0.0.1".to_string()
}

fn default_batch_mode() -> bool {
    true
}

fn default_connect_timeout() -> u16 {
    10
}
