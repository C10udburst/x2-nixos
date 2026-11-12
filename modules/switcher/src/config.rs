use std::ffi::OsString;
use std::path::PathBuf;
use std::time::Duration;

use crate::registry::Registry;
use crate::workload::{Paths, Runner};

#[derive(Debug, Clone)]
pub enum Listen {
    Unix(PathBuf),
    Tcp(std::net::SocketAddr),
}


#[derive(Clone)]
pub struct Config {
    pub registry: Registry,
    pub listen: Vec<Listen>,
    /// Permissions of the Unix socket. The parent directory is expected to carry the group of
    /// whoever may connect (nginx), so `0660` is the usual answer.
    pub socket_mode: u32,

    // --- workload orchestration (see modules/workload-manager.nix) ---
    pub paths: Paths,
    pub runner: Runner,
    pub health_paths: Vec<String>,
    pub startup_timeout: Duration,

    // --- hot-path tunables ---
    /// Ceiling on a request head; anything bigger is a client error, not a body.
    pub max_header: usize,
    /// Ceiling on a request **body**. The router must hold it to find the model id, so this is
    /// what stops a multi-gigabyte upload from being buffered into RAM.
    pub max_body: usize,
    /// Idle keep-alive sockets per backend.
    pub pool_max: usize,
    pub pool_idle: Duration,
    /// How long a client connection may sit idle between requests. Guards against a kept-alive
    /// connection pinning a worker thread forever.
    pub client_idle: Duration,
    /// Deadline for writing a response to the client.
    pub client_write: Duration,
    /// Deadlines for reading from / writing to a backend.
    pub backend_read: Duration,
    pub backend_write: Duration,
    pub connect_timeout: Duration,
    /// Worker thread stack size; the relay is shallow, 256 KiB is generous.
    pub worker_stack: usize,
    /// Upper bound on concurrent workers. Each connection owns a thread, so this is the real
    /// concurrency limit and the reason an overload answers 503 instead of thrashing.
    pub worker_max: usize,
}

const HELP: &str = "\
switcher - model router for the EVO-X2 inference gateway

Reads the Nix-generated registry, resolves the model a request names, makes sure that
model is the resident workload of its own domain(s), and relays the exchange verbatim.

USAGE:
    switcher [OPTIONS]

OPTIONS:
    --registry PATH             registry file (required)
    --listen SPEC               unix:/run/switcher/switcher.sock | tcp:127.0.0.1:8082
                                (repeatable; defaults to unix:/run/switcher/switcher.sock)
    --socket-mode MODE          octal mode of the unix socket (default 0660)
    --lock-dir DIR              workload lock/state directory (default /run/model-lock)
    --systemctl PATH            systemctl binary to drive (default systemctl)
    --sudo PATH                 run systemctl through this sudo (default /run/wrappers/bin/sudo;
                                empty string calls systemctl directly)
    --stop-script PATH          eval-time stop-other-workloads script (empty = never stop others)
    --health-paths LIST         readiness probe paths (default /health,/v1/models,/)
    --startup-timeout SECONDS   how long a model may take to load (default 180)
    --max-body BYTES             largest request body accepted (default 536870912)
    --max-header BYTES          maximum request head size (default 131072)
    --pool-max N                idle backend sockets per model (default 8)
    --pool-idle SECONDS         discard idle backend sockets after this (default 20)
    --client-idle SECONDS       keep-alive timeout for a client connection (default 300)
    --client-write SECONDS      deadline for writing a response (default 900)
    --backend-read SECONDS      deadline for reading a response (default 1800)
    --backend-write SECONDS     deadline for forwarding a request body (default 900)
    --connect-timeout SECONDS   backend connect deadline (default 5)
    --worker-stack KILOBYTES    worker thread stack size (default 256)
    --worker-max N              concurrent connections (default 512)
    --help                      show this text
";

impl Config {
    pub fn from_args<I: IntoIterator<Item = String>>(args: I) -> Result<Config, String> {
        let mut registry_path: Option<PathBuf> = None;
        let mut listen: Vec<Listen> = Vec::new();
        let mut socket_mode = 0o660;
        let mut lock_dir = PathBuf::from("/run/model-lock");
        let mut sudo: Option<OsString> = Some(OsString::from("/run/wrappers/bin/sudo"));
        let mut systemctl = OsString::from("systemctl");
        let mut stop_script: Option<PathBuf> = None;
        let mut health_paths = vec![
            "/health".to_string(),
            "/v1/models".to_string(),
            "/".to_string(),
        ];
        let mut startup_timeout = Duration::from_secs(180);
        let mut max_body = 512 * 1024 * 1024usize;
        let mut max_header = 128 * 1024usize;
        let mut pool_max = 8usize;
        let mut pool_idle = Duration::from_secs(20);
        let mut client_idle = Duration::from_secs(300);
        let mut client_write = Duration::from_secs(900);
        let mut backend_read = Duration::from_secs(1800);
        let mut backend_write = Duration::from_secs(900);
        let mut connect_timeout = Duration::from_secs(5);
        let mut worker_stack = 256 * 1024usize;
        let mut worker_max = 512usize;

        let argv: Vec<String> = args.into_iter().collect();
        let mut i = 0;
        // Take the value of `--key value` (also accepts `--key=value`).
        macro_rules! value {
            () => {{
                let item = argv[i].clone();
                match item.split_once('=') {
                    Some((_, inline)) if item.starts_with("--") => inline.to_string(),
                    _ => {{
                        i += 1;
                        argv.get(i).cloned().ok_or_else(|| {{
                            format!("{} needs a value", item.split('=').next().unwrap_or(""))
                        }})?
                    }}
                }
            }};
        }
        while i < argv.len() {
            let key = argv[i].split('=').next().unwrap_or("").to_string();
            match key.as_str() {
                "--help" | "-h" => {
                    println!("{HELP}");
                    std::process::exit(0);
                }
                "--registry" => registry_path = Some(PathBuf::from(value!())),
                "--listen" => {
                    let spec = value!();
                    listen.push(parse_listen(&spec)?);
                }
                "--socket-mode" => {
                    socket_mode = u32::from_str_radix(value!().trim_start_matches("0o"), 8)
                        .map_err(|err| format!("bad --socket-mode: {err}"))?
                }
                "--lock-dir" => lock_dir = PathBuf::from(value!()),
                "--sudo" => {
                    let value = value!();
                    sudo = if value.is_empty() { None } else { Some(value.into()) };
                }
                "--systemctl" => systemctl = value!().into(),
                "--stop-script" => {
                    let value = value!();
                    stop_script = if value.is_empty() {
                        None
                    } else {
                        Some(PathBuf::from(value))
                    };
                }
                "--health-paths" => {
                    health_paths = value!()
                        .split(',')
                        .map(str::trim)
                        .filter(|path| !path.is_empty())
                        .map(str::to_string)
                        .collect()
                }
                "--startup-timeout" => startup_timeout = Duration::from_secs(seconds(&value!())?),
                "--max-header" => max_header = value!().parse().map_err(bad(&key))?,
                "--max-body" => max_body = value!().parse().map_err(bad(&key))?,
                "--pool-max" => pool_max = value!().parse().map_err(bad(&key))?,
                "--pool-idle" => pool_idle = Duration::from_secs(seconds(&value!())?),
                "--client-idle" => client_idle = Duration::from_secs(seconds(&value!())?),
                "--client-write" => client_write = Duration::from_secs(seconds(&value!())?),
                "--backend-read" => backend_read = Duration::from_secs(seconds(&value!())?),
                "--backend-write" => backend_write = Duration::from_secs(seconds(&value!())?),
                "--connect-timeout" => connect_timeout = Duration::from_secs(seconds(&value!())?),
                "--worker-stack" => worker_stack = value!().parse::<usize>().map_err(bad(&key))? * 1024,
                "--worker-max" => worker_max = value!().parse().map_err(bad(&key))?,
                other => return Err(format!("unknown option {other}")),
            }
            i += 1;
        }

        if listen.is_empty() {
            listen.push(Listen::Unix(PathBuf::from(
                "/run/switcher/switcher.sock",
            )));
        }
        let path = registry_path.ok_or("--registry is required")?;
        let text = std::fs::read_to_string(&path)
            .map_err(|err| format!("cannot read {}: {err}", path.display()))?;
        let registry = Registry::parse(&text).map_err(|err| format!("{}: {err}", path.display()))?;
        if registry.is_empty() {
            return Err(format!("{} declares no models", path.display()));
        }

        Ok(Config {
            registry,
            listen,
            socket_mode,
            paths: Paths { lock_dir },
            runner: Runner {
                sudo,
                systemctl,
                stop_script,
            },
            health_paths,
            startup_timeout,
            max_body,
            max_header,
            pool_max,
            pool_idle,
            client_idle,
            client_write,
            backend_read,
            backend_write,
            connect_timeout,
            worker_stack,
            worker_max,
        })
    }
}



fn bad(key: &str) -> impl Fn(std::num::ParseIntError) -> String + '_ {{
    move |err| format!("bad {key}: {err}")
}}

fn seconds(text: &str) -> Result<u64, String> {{
    text.trim().parse().map_err(|err| format!("bad duration {text:?}: {err}"))
}}

fn parse_listen(spec: &str) -> Result<Listen, String> {
    if let Some(path) = spec.strip_prefix("unix:") {
        Ok(Listen::Unix(PathBuf::from(path)))
    } else if let Some(addr) = spec.strip_prefix("tcp:") {
        addr.parse::<std::net::SocketAddr>()
            .map(Listen::Tcp)
            .map_err(|err| format!("bad tcp listen address {addr:?}: {err}"))
    } else {
        Err(format!(
            "--listen expects unix:PATH or tcp:HOST:PORT, got {spec:?}"
        ))
    }
}
