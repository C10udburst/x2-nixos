//! Socket abstraction shared by the listener, the pool and the relay.
//!
//! The router answers nginx on a Unix socket (cheap, and access is a file permission instead
//! of a firewall rule) and optionally on a loopback TCP port for direct `curl` during
//! development. Both are the same stream to the relay.

use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::io::{AsRawFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::time::Duration;

pub enum Stream {
    Unix(UnixStream),
    Tcp(TcpStream),
}

impl Stream {


    /// Blocking sockets with explicit deadlines: a worker that hangs forever is worse than a
    /// dropped request, and the deadlines differ per direction (a token stream may be quiet
    /// for a long time, a stalled write is a dead peer).
    pub fn set_timeouts(&self, read: Duration, write: Duration) -> io::Result<()> {
        let (read, write) = (Some(read), Some(write));
        match self {
            Stream::Unix(s) => {
                s.set_read_timeout(read)?;
                s.set_write_timeout(write)
            }
            Stream::Tcp(s) => {
                s.set_read_timeout(read)?;
                s.set_write_timeout(write)
            }
        }
    }

    /// Token streams must not wait for Nagle.
    pub fn set_nodelay(&self) -> io::Result<()> {
        match self {
            Stream::Unix(_) => Ok(()),
            Stream::Tcp(s) => s.set_nodelay(true),
        }
    }


}

impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Stream::Unix(s) => s.read(buf),
            Stream::Tcp(s) => s.read(buf),
        }
    }
}

impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Stream::Unix(s) => s.write(buf),
            Stream::Tcp(s) => s.write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Stream::Unix(s) => s.flush(),
            Stream::Tcp(s) => s.flush(),
        }
    }
}

impl AsRawFd for Stream {
    fn as_raw_fd(&self) -> RawFd {
        match self {
            Stream::Unix(s) => s.as_raw_fd(),
            Stream::Tcp(s) => s.as_raw_fd(),
        }
    }
}

/// A bound listener, either family.
pub enum Listener {
    Unix(UnixListener, std::path::PathBuf),
    Tcp(TcpListener),
}

impl Listener {
    pub fn bind_unix(path: &std::path::Path, mode: u32) -> io::Result<Listener> {
        // A stale socket from a killed daemon would block bind() forever.
        if path.exists() {
            std::fs::remove_file(path)?;
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let listener = UnixListener::bind(path)?;
        std::fs::set_permissions(
            path,
            std::os::unix::fs::PermissionsExt::from_mode(mode),
        )?;
        Ok(Listener::Unix(listener, path.to_path_buf()))
    }

    pub fn bind_tcp(addr: std::net::SocketAddr) -> io::Result<Listener> {
        Ok(Listener::Tcp(TcpListener::bind(addr)?))
    }

    pub fn local_addr(&self) -> String {
        match self {
            Listener::Unix(_, path) => format!("unix:{}", path.display()),
            Listener::Tcp(l) => l
                .local_addr()
                .map(|a| format!("tcp:{a}"))
                .unwrap_or_else(|_| "tcp:?".into()),
        }
    }

    /// Block until nginx (or a developer) connects. A parked thread costs no CPU at all, which
    /// is what keeps an idle gateway at zero cycles.
    pub fn accept(&self) -> io::Result<(Stream, String)> {
        match self {
            Listener::Unix(l, _) => l.accept().map(|(s, _)| (Stream::Unix(s), "unix".into())),
            Listener::Tcp(l) => l
                .accept()
                .map(|(s, peer)| (Stream::Tcp(s), peer.to_string())),
        }
    }
}
