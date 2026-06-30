use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::net::TcpListener;
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

#[derive(Clone, Debug, Deserialize)]
pub struct SshConfig {
    pub host: String,
    pub user: Option<String>,
    #[serde(default = "default_ssh_port")]
    pub port: u16,
    pub identity_file: Option<String>,
    #[serde(default = "default_local_host")]
    pub local_host: String,
    pub local_port: Option<u16>,
    #[serde(default = "default_remote_host")]
    pub remote_host: String,
    #[serde(default = "default_mariadb_port")]
    pub remote_port: u16,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct TunnelHandle {
    pub pid: u32,
    pub local_host: String,
    pub local_port: u16,
    pub remote_host: String,
    pub remote_port: u16,
}

pub fn open_tunnel(ssh: SshConfig) -> Result<TunnelHandle> {
    let local_port = match ssh.local_port {
        Some(0) | None => free_port(&ssh.local_host)?,
        Some(port) => port,
    };
    let destination = format!(
        "{}:{}:{}:{}",
        ssh.local_host, local_port, ssh.remote_host, ssh.remote_port
    );
    let target = match &ssh.user {
        Some(user) => format!("{user}@{}", ssh.host),
        None => ssh.host.clone(),
    };

    let mut command = Command::new("ssh");
    command
        .arg("-N")
        .arg("-L")
        .arg(destination)
        .arg("-p")
        .arg(ssh.port.to_string())
        .arg("-o")
        .arg("ExitOnForwardFailure=yes")
        .arg("-o")
        .arg("ServerAliveInterval=30");

    if let Some(identity_file) = &ssh.identity_file {
        command.arg("-i").arg(identity_file);
    }

    let mut child = command
        .arg(target)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("failed to start ssh tunnel")?;

    thread::sleep(Duration::from_millis(150));
    if let Some(status) = child.try_wait().context("failed to inspect ssh tunnel")? {
        return Err(anyhow!("ssh tunnel exited early with status {status}"));
    }

    Ok(TunnelHandle {
        pid: child.id(),
        local_host: ssh.local_host,
        local_port,
        remote_host: ssh.remote_host,
        remote_port: ssh.remote_port,
    })
}

pub fn close_tunnel(tunnel: TunnelHandle) -> Result<()> {
    let status = Command::new("kill")
        .arg(tunnel.pid.to_string())
        .status()
        .context("failed to stop ssh tunnel")?;
    if status.success() {
        Ok(())
    } else {
        Err(anyhow!("ssh tunnel process {} did not stop", tunnel.pid))
    }
}

fn free_port(host: &str) -> Result<u16> {
    let listener = TcpListener::bind((host, 0)).context("failed to reserve local tunnel port")?;
    Ok(listener.local_addr()?.port())
}

fn default_mariadb_port() -> u16 {
    3306
}

fn default_ssh_port() -> u16 {
    22
}

fn default_local_host() -> String {
    "127.0.0.1".to_string()
}

fn default_remote_host() -> String {
    "127.0.0.1".to_string()
}
