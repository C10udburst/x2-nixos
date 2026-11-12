//! Workload orchestration: the per-domain lock, the state files, systemd, readiness.
//!
//! The protocol is byte-for-byte the one `modules/workload-manager.nix`, the wake scripts and
//! `dash.py` already implement, so the router is a drop-in citizen of the existing scheme:
//!
//! ```text
//! /run/model-lock/gpu.lock   flock(2)   ->  serialization inside the GPU domain
//! /run/model-lock/npu.lock   flock(2)   ->  serialization inside the NPU domain
//! /run/model-lock/active_gpu            ->  registry id of the resident GPU workload, or ""
//! /run/model-lock/active_npu            ->  registry id of the resident NPU workload, or ""
//! ```
//!
//! Two rules keep Rule 1 and the deadlock-freedom argument intact:
//!
//! 1. **A model is resident only when every domain it declares names it.** Today every entry
//!    declares exactly one domain, so this is the old single-file check; the day a model needs
//!    `gpu,npu` it becomes a two-file check without touching this logic.
//! 2. **Locks are taken in [`Device::LOCK_ORDER`] and never out of order.** A multi-domain
//!    model takes `gpu` then `npu`; every other orchestrator holds exactly one lock, so no
//!    cycle can form.
//!
//! There is deliberately **no cache** in front of the state files: they live in tmpfs, a read
//! is a couple of microseconds, and a stale answer here is a request forwarded to the wrong
//! engine - the worst possible trade.

use std::ffi::OsString;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::net::{IpAddr, SocketAddr, ToSocketAddrs};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::ffi;
use crate::registry::{Device, Entry};

/// Anything the request path needs to answer with an HTTP status.
#[derive(Debug)]
pub struct Fail {
    pub status: u16,
    pub kind: &'static str,
    pub message: String,
}

impl Fail {
    pub fn new(status: u16, kind: &'static str, message: impl Into<String>) -> Fail {
        Fail {
            status,
            kind,
            message: message.into(),
        }
    }
}

impl From<std::io::Error> for Fail {
    fn from(err: std::io::Error) -> Fail {
        Fail::new(502, "bad_gateway", format!("io error: {err}"))
    }
}

/// `/run/model-lock` + the `active_<device>` naming convention.
#[derive(Clone)]
pub struct Paths {
    pub lock_dir: PathBuf,
}

impl Paths {
    pub fn lock_file(&self, device: Device) -> PathBuf {
        self.lock_dir.join(format!("{}.lock", device))
    }

    pub fn state_file(&self, device: Device) -> PathBuf {
        self.lock_dir.join(format!("active_{device}"))
    }
}

/// An `flock(2)` on one domain's lock file. Dropping it releases the domain.
pub struct DomainLock {
    file: File,
}

impl DomainLock {
    /// Block until the domain is ours. Files are created 0666 by `systemd.tmpfiles`; opening
    /// read-write (creating if absent) matches `dash.py:acquire_lock`.
    pub fn acquire(paths: &Paths, device: Device) -> Result<DomainLock, Fail> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o666)
            .open(paths.lock_file(device))
            .map_err(|err| {
                Fail::new(
                    500,
                    "server_error",
                    format!("cannot open domain lock: {err}"),
                )
            })?;
        ffi::flock_ex(file.as_raw_fd()).map_err(|err| {
            Fail::new(500, "server_error", format!("cannot lock domain: {err}"))
        })?;
        Ok(DomainLock { file })
    }

    /// Take every domain a model needs, in canonical order, deduplicated.
    ///
    /// The returned `Vec` drops in reverse order, which is fine: locks are only ever taken in
    /// one global order, so the last one held is released first and no waiter can be starved.
    /// Take every domain a model needs, **in [`Device::LOCK_ORDER`]**, deduplicated.
    ///
    /// Sorting here is not cosmetic: it is the single place that guarantees every orchestrator
    /// acquires locks in the same global order, which is what makes a future `gpu,npu` model
    /// deadlock-free against the wake scripts and the dashboard.
    pub fn acquire_all(paths: &Paths, devices: &[Device]) -> Result<Vec<DomainLock>, Fail> {
        let mut ordered: Vec<Device> = Device::LOCK_ORDER
            .iter()
            .copied()
            .filter(|device| devices.contains(device))
            .collect();
        // Anything outside the declared order (a new variant not yet listed) still gets locked,
        // just last, so no request can be routed without its domain being serialized.
        for device in devices {
            if !ordered.contains(device) {
                ordered.push(*device);
            }
        }
        let mut held = Vec::with_capacity(ordered.len());
        for device in ordered {
            held.push(DomainLock::acquire(paths, device)?);
        }
        Ok(held)
    }
}

impl Drop for DomainLock {
    fn drop(&mut self) {
        ffi::funlock(self.file.as_raw_fd());
    }
}

/// Read `/run/model-lock/active_<device>`. `None` means "nothing resident in this domain".
pub fn read_active(paths: &Paths, device: Device) -> Option<String> {
    let mut text = String::new();
    File::open(paths.state_file(device))
        .and_then(|mut f| f.read_to_string(&mut text))
        .ok()
        .map(|_| text.trim().to_string())
        .filter(|trimmed| !trimmed.is_empty())
}

/// Write the domain's active workload, tolerating a file owned by another workload user:
/// every `mkGufo`/`mkLlamaCpp`/`mkNpuModel` unit also writes this file from `ExecStartPre`
/// (as `gufo`, `kyojin`, ...), so a plain reopen-and-truncate can hit `EACCES`. Unlinking and
/// recreating inside the 0777 directory is what `dash.py:set_state_file` does for the same
/// reason.
pub fn write_active(paths: &Paths, device: Device, model_id: &str) -> Result<(), Fail> {
    let path = paths.state_file(device);
    let attempt = || -> std::io::Result<()> {
        let mut file = File::options()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)?;
        file.write_all(model_id.as_bytes())?;
        let _ = file.set_permissions(std::fs::Permissions::from_mode(0o666));
        Ok(())
    };
    attempt().or_else(|first| {
        let _ = std::fs::remove_file(&path);
        attempt().map_err(|err| {
            Fail::new(
                500,
                "server_error",
                format!("cannot write {}: {first} / {err}", path.display()),
            )
        })
    })
}

/// How to talk to systemd. Everything goes through `sudo -n systemctl`, exactly like the
/// FastCGI path did: the router runs as the unprivileged `gateway`-peer user `switcher` and
/// `security.sudo.extraRules` grants it the store path of `systemctl` and of the eval-time
/// `stop-other-workloads` script.
///
/// Forking `systemctl` costs milliseconds. That is only ever paid on the cold path, where the
/// alternative (a D-Bus client) would buy nothing: the model behind it takes seconds to load.
#[derive(Clone)]
pub struct Runner {
    pub sudo: Option<OsString>,
    pub systemctl: OsString,
    pub stop_script: Option<PathBuf>,
}

impl Runner {
    fn run(&self, args: &[&str]) -> Result<String, Fail> {
        let mut cmd = self.systemctl_command(args);
        cmd.stdin(Stdio::null());
        let output = cmd.output().map_err(|err| {
            Fail::new(
                500,
                "server_error",
                format!("cannot run systemctl {:?}: {err}", args),
            )
        })?;
        let mut text = String::from_utf8_lossy(&output.stdout).to_string();
        let err = String::from_utf8_lossy(&output.stderr).to_string();
        if !err.is_empty() {
            text.push_str(&err);
        }
        if output.status.success() {
            Ok(text)
        } else {
            Err(Fail::new(
                500,
                "server_error",
                format!("systemctl {} failed: {}", args.join(" "), one_line(&text)),
            ))
        }
    }

    fn systemctl_command(&self, args: &[&str]) -> Command {
        match &self.sudo {
            Some(sudo) => {
                let mut cmd = Command::new(sudo);
                cmd.arg("-n").arg(&self.systemctl).args(args);
                cmd
            }
            None => {
                let mut cmd = Command::new(&self.systemctl);
                cmd.args(args);
                cmd
            }
        }
    }

    pub fn start(&self, unit: &str) -> Result<(), Fail> {
        self.run(&["start", unit]).map(|_| ())
    }

    /// `ActiveState` of a unit (`activating`, `active`, `failed`, `inactive`, ...). Empty when
    /// systemd could not be asked at all, which the caller treats as "unknown, keep waiting".
    pub fn active_state(&self, unit: &str) -> String {
        self.run(&["show", "-p", "ActiveState", "--value", unit])
            .map(|state| state.trim().to_string())
            .unwrap_or_default()
    }

    /// Only used to recover from a state file that claimed a workload was resident while its
    /// socket was dead (SIGKILL, OOM, a crash that skipped `ExecStopPost`).
    pub fn restart(&self, unit: &str) -> Result<(), Fail> {
        self.run(&["restart", unit]).map(|_| ())
    }

    /// Stop every *other* workload of one domain using the eval-time generated script, which
    /// holds the authoritative per-domain unit list.
    ///
    /// This **must** succeed before anything is started. `Conflicts=` alone is not enough: the
    /// eviction it triggers is asynchronous, and `Type=simple` makes `systemctl start` return as
    /// soon as the new process is forked - so the new model begins `hipMalloc`ing while the old
    /// one still holds 100 GB of the unified pool and dies on `hipMalloc failed` seconds later.
    /// `systemctl stop` inside the script blocks until the conflicting units are really gone
    /// (up to their `TimeoutStopSec`, then SIGKILL), which is the point of paying for it.
    pub fn stop_other_workloads(&self, device: Device, target_unit: &str) -> Result<(), Fail> {
        let Some(script) = &self.stop_script else {
            return Ok(());
        };
        let mut cmd = match &self.sudo {
            Some(sudo) => {
                let mut cmd = Command::new(sudo);
                cmd.arg("-n").arg(script);
                cmd
            }
            None => Command::new(script),
        };
        cmd.arg(device.as_str()).arg(target_unit);
        cmd.stdin(Stdio::null());
        let output = cmd.output().map_err(|err| {
            Fail::new(
                500,
                "server_error",
                format!("cannot run stop-other-workloads: {err}"),
            )
        })?;
        if output.status.success() {
            return Ok(());
        }
        // Loud on purpose: a workload that refuses to die means the next one would OOM.
        Err(Fail::new(
            500,
            "server_error",
            format!(
                "could not unload the other {} workloads: {}",
                device,
                one_line(&String::from_utf8_lossy(&output.stderr))
            ),
        ))
    }
}

/// One probe round: `GET <path>` on each readiness path, accepting any answer below 500
/// (same rule as `dash.py:check_url_health`, since a backend may 404 `/health` and still be
/// perfectly usable).
fn probe(addr: SocketAddr, paths: &[String], timeout: Duration) -> bool {
    for path in paths {
        let Ok(mut stream) = TcpStream::connect_timeout(&addr, timeout) else {
            continue;
        };
        let _ = stream.set_read_timeout(Some(timeout));
        let _ = stream.set_write_timeout(Some(timeout));
        let request = format!(
            "GET {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\nAccept: */*\r\n\r\n"
        );
        if stream.write_all(request.as_bytes()).is_err() {
            continue;
        }
        let mut head = [0u8; 24];
        let mut filled = 0usize;
        while filled < head.len() {
            match stream.read(&mut head[filled..]) {
                Ok(0) => break,
                Ok(got) => filled += got,
                Err(err) if err.kind() == std::io::ErrorKind::Interrupted => {}
                Err(_) => break,
            }
        }
        // "HTTP/1.1 404 ..." -> 404
        let code: u16 = match std::str::from_utf8(&head[..filled]) {
            Ok(text) => text
                .split_whitespace()
                .nth(1)
                .and_then(|code| code.parse().ok())
                .unwrap_or(999),
            Err(_) => 999,
        };
        if code < 500 {
            return true;
        }
    }
    false
}

/// Resolve a backend host once per use, with a literal-IP fast path (`127.0.0.1` is the only
/// thing a registry entry ever is in practice, and `getaddrinfo` on the hot path is silly).
pub fn backend_addr(entry: &Entry) -> Result<SocketAddr, Fail> {
    if let Ok(ip) = entry.host.parse::<IpAddr>() {
        return Ok(SocketAddr::new(ip, entry.port));
    }
    (entry.host.as_str(), entry.port)
        .to_socket_addrs()
        .and_then(|mut addrs| {
            addrs.next().ok_or_else(|| {
                std::io::Error::new(std::io::ErrorKind::NotFound, "no address for backend host")
            })
        })
        .map_err(|err| {
            Fail::new(
                500,
                "server_error",
                format!("cannot resolve backend {}: {err}", entry.authority()),
            )
        })
}

/// Everything needed to bring a workload up.
pub struct Workload {
    pub paths: Paths,
    pub runner: Runner,
    /// Readiness probe paths, tried in order.
    pub health_paths: Vec<String>,
    /// How long a starting model may take (a 300 GB GGUF really does need minutes).
    pub startup_timeout: Duration,
}

use std::net::TcpStream;

impl Workload {
    /// The hot-path question: is this model already the resident workload of every domain it
    /// needs? Two tmpfs reads at most, no `systemctl`, no connect, no fork.
    pub fn is_resident(&self, entry: &Entry) -> bool {
        entry
            .devices
            .iter()
            .all(|device| read_active(&self.paths, *device).as_deref() == Some(entry.id.as_str()))
    }

    /// The state file names `entry`, but systemd says its unit is not running - the state file
    /// lied. Every model unit claims its domain in `ExecStartPre`, so a start that fails after
    /// the claim (bad weights, `hipMalloc` OOM because the previous workload was not gone yet)
    /// leaves the domain pointing at a process that does not exist, and the resident fast path
    /// would then answer every request with a refused connection forever.
    ///
    /// An unreadable state is reported as "not dead": guessing here would restart a healthy
    /// 100 GB model.
    pub fn claims_but_dead(&self, entry: &Entry) -> bool {
        let state = self.runner.active_state(&entry.service);
        !state.is_empty() && !matches!(state.as_str(), "active" | "activating" | "reloading")
    }

    /// Make `entry` the resident workload, returning whether anything was actually started.
    ///
    /// `force` skips the resident fast path and restarts the unit: it is the recovery move for
    /// a state file that lied (a workload killed with SIGKILL never runs its `ExecStopPost`, so
    /// `active_gpu` can still name a process that is gone).
    pub fn ensure(&self, entry: &Entry, force: bool) -> Result<bool, Fail> {
        if !force && self.is_resident(entry) {
            return Ok(false);
        }

        // Serialize per domain, in canonical order. Everything else - the dashboard's
        // /api/switch, a wake socket handling its first connection, another inference request -
        // respects the same lock.
        let _locks = DomainLock::acquire_all(&self.paths, &entry.devices)?;

        // Re-check under the lock: the workload we want may have come up while we queued.
        if !force && self.is_resident(entry) {
            return Ok(false);
        }

        // Fail fast on weights that were never downloaded, *before* spending minutes on a unit
        // start that would only fail in the journal.
        if !entry.model_dir.is_empty() && !Path::new(&entry.model_dir).is_dir() {
            return Err(Fail::new(
                503,
                "service_unavailable",
                format!(
                    "model {} is not downloaded: {} is missing",
                    entry.id, entry.model_dir
                ),
            ));
        }

        // Rule 1, per domain: stop the other workloads of every domain this model joins, and
        // wait for it. Starting on top of a workload that is still resident is a guaranteed OOM.
        for device in &entry.devices {
            self.runner.stop_other_workloads(*device, &entry.service)?;
        }

        let started_at = Instant::now();
        if force {
            self.runner.restart(&entry.service)?;
        } else {
            self.runner.start(&entry.service)?;
        }

        let addr = backend_addr(entry)?;
        let mut delay = Duration::from_millis(25);
        let deadline = Instant::now() + self.startup_timeout;
        let mut last_unit_check = Instant::now();
        loop {
            if probe(addr, &self.health_paths, Duration::from_millis(1500)) {
                break;
            }
            // A unit that already went to `failed` will never answer - a model that could not
            // allocate is the common case here. Say so immediately instead of letting the client
            // wait out the full startup timeout for a process that is gone.
            if last_unit_check.elapsed() >= Duration::from_secs(2) {
                last_unit_check = Instant::now();
                let state = self.runner.active_state(&entry.service);
                if matches!(state.as_str(), "failed" | "inactive" | "deactivating") {
                    return Err(Fail::new(
                        502,
                        "bad_gateway",
                        format!(
                            "{} is {} immediately after starting: the load failed - see `journalctl -u {}`",
                            entry.service, state, entry.service
                        ),
                    ));
                }
            }
            if Instant::now() >= deadline {
                return Err(Fail::new(
                    504,
                    "gateway_timeout",
                    format!(
                        "{} did not become responsive within {}s on {}",
                        entry.service,
                        self.startup_timeout.as_secs(),
                        addr
                    ),
                ));
            }
            std::thread::sleep(delay);
            delay = (delay * 2).min(Duration::from_millis(500));
        }

        // The unit's own ExecStartPre already published this; writing it again makes the router
        // self-contained for units that do not (and is idempotent for the ones that do).
        for device in &entry.devices {
            write_active(&self.paths, *device, &entry.id)?;
        }
        eprintln!(
            "switcher: {} resident on {} ({} domain(s)) in {:.1}s",
            entry.id,
            entry.authority(),
            entry.devices.len(),
            started_at.elapsed().as_secs_f64()
        );
        Ok(true)
    }
}

/// Collapse systemd's multi-line journal-ish noise into one log line.
fn one_line(text: &str) -> String {
    let mut out = text.trim().replace('\n', " ");
    out.truncate(400);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A private scratch directory per test **and per process**, so a leftover state file from
    /// an earlier run (or a concurrently running test binary) can never satisfy an assertion.
    fn dir(tag: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "switcher-test-{}-{}",
            tag,
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("scratch dir");
        path
    }

    #[test]
    fn state_files_round_trip_per_domain() {
        let paths = Paths {
            lock_dir: dir("state"),
        };
        assert_eq!(read_active(&paths, Device::Gpu), None);
        write_active(&paths, Device::Gpu, "ripple-65b").unwrap();
        assert_eq!(
            read_active(&paths, Device::Gpu).as_deref(),
            Some("ripple-65b")
        );
        // The domains stay independent: writing one never touches the other.
        assert_eq!(read_active(&paths, Device::Npu), None);
        assert!(paths.lock_file(Device::Gpu).ends_with("gpu.lock"));
        assert!(paths.state_file(Device::Npu).ends_with("active_npu"));
    }

    #[test]
    fn resident_requires_every_declared_domain() {
        let paths = Paths {
            lock_dir: dir("resident"),
        };
        let workload = Workload {
            paths,
            runner: Runner {
                sudo: None,
                systemctl: "/bin/true".into(),
                stop_script: None,
            },
            health_paths: vec!["/health".into()],
            startup_timeout: Duration::from_secs(1),
        };
        let entry = Entry {
            devices: vec![Device::Gpu, Device::Npu],
            id: "hybrid".into(),
            service: "hybrid.service".into(),
            remapped: "hybrid".into(),
            host: "127.0.0.1".into(),
            port: 1,
            model_dir: String::new(),
            engine: "test".into(),
        };
        write_active(&workload.paths, Device::Gpu, "hybrid").unwrap();
        assert!(!workload.is_resident(&entry), "gpu alone is not resident");
        write_active(&workload.paths, Device::Npu, "hybrid").unwrap();
        assert!(workload.is_resident(&entry));
        write_active(&workload.paths, Device::Npu, "something-else").unwrap();
        assert!(!workload.is_resident(&entry));
    }

    #[test]
    fn domain_locks_are_mutually_exclusive() {
        let paths = Paths {
            lock_dir: dir("lock"),
        };
        let held = DomainLock::acquire(&paths, Device::Gpu).unwrap();
        // Non-blocking probe from a second descriptor must fail while `held` is alive.
        let probe = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(paths.lock_file(Device::Gpu))
            .unwrap();
        let blocked = {
            use std::os::unix::io::AsRawFd;
            extern "C" {
                fn flock(fd: i32, op: i32) -> i32;
            }
            unsafe { flock(probe.as_raw_fd(), 2 | 1) } // LOCK_EX | LOCK_NB
        };
        assert_ne!(blocked, 0, "second LOCK_EX must block");
        // The other domain is unaffected.
        let _npu: Vec<DomainLock> = DomainLock::acquire_all(&paths, &[Device::Npu]).unwrap();
        drop(held);
    }

    #[test]
    fn backend_addr_fast_path() {
        let entry = Entry {
            devices: vec![Device::Gpu],
            id: "x".into(),
            service: "x.service".into(),
            remapped: "x".into(),
            host: "127.0.0.1".into(),
            port: 8081,
            model_dir: String::new(),
            engine: "t".into(),
        };
        assert_eq!(
            backend_addr(&entry).unwrap(),
            "127.0.0.1:8081".parse().unwrap()
        );
    }
}
