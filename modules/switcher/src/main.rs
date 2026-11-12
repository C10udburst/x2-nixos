mod config;
mod ffi;
mod http;
mod pool;
mod registry;
mod relay;
mod scan;
mod stream;
mod workload;

use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::sync::Arc;
use std::thread;

use crate::config::{Config, Listen};
use crate::http::Framing;
use crate::pool::Pool;
use crate::registry::Registry;
use crate::stream::Stream;
use crate::workload::{backend_addr as resolve_backend_addr, Workload};

// ---------------------------------------------------------------------------
// Worker: one client connection -> read head/body -> resolve workload -> relay -> respond
// ---------------------------------------------------------------------------

/// Serve one client connection until either side asks to close.
///
/// nginx multiplexes many requests over a single upstream connection, so this is a loop and
/// not a one-shot: returning after one exchange would break every keep-alive client. Bytes the
/// kernel handed us past the end of a message are kept in `buf` and reused for the next head,
/// which is what makes pipelining and back-to-back requests lossless.
fn handle_connection(stream: Stream, router: &Router) -> io::Result<()> {
    let cfg = &router.config;
    // Idle read timeout: a keep-alive connection that never sends another request must not pin
    // a worker thread forever. Writes use their own (longer) deadline because a big response to
    // a slow client is legitimate.
    stream.set_timeouts(cfg.client_idle, cfg.client_write)?;
    let mut conn = BufReader::new(stream);

    loop {
        match serve_one_request(&mut conn, router) {
            Ok(true) => continue,
            Ok(false) => return Ok(()),
            Err(err) => {
                // A client that hangs up mid-request is routine (browser tab closed); anything
                // else is worth a line in the journal.
                if !matches!(
                    err.kind(),
                    io::ErrorKind::UnexpectedEof | io::ErrorKind::ConnectionReset
                ) {
                    eprintln!("switcher: {err}");
                }
                return Ok(());
            }
        }
    }
}

/// One request/response exchange. `Ok(true)` means the connection may be reused.
fn serve_one_request(conn: &mut BufReader, router: &Router) -> io::Result<bool> {
    let cfg = &router.config;
    let started = std::time::Instant::now();

    // --- request head (+ whatever body bytes arrived with it) ---------------
    let Some(head) = conn.read_head(cfg.max_header)? else {
        return Ok(false); // clean client EOF between requests
    };
    let framing = head.request_framing();

    // Read the body into memory only when we must inspect it for a model id. A body that
    // already named its model in the target or a header still needs its bytes forwarded, so
    // `Framing::Length` is always consumed here.
    let mut body = Vec::new();
    match framing {
        Framing::Length(len) => {
            // The model id lives inside the body, so it must be buffered - refuse anything
            // larger than the configured ceiling instead of letting a client size the heap.
            if len > cfg.max_body as u64 {
                http::write_error(
                    conn,
                    413,
                    "invalid_request_error",
                    &format!("Request body of {len} bytes exceeds the {} byte limit",
                             cfg.max_body),
                )?;
                return Ok(false);
            }
            conn.read_exact_into(&mut body, len)?
        }
        Framing::Chunked => {
            conn.read_chunked_body(&mut body, cfg.max_body)?;
        }
        Framing::None | Framing::UntilEof => {}
    }

    // --- resolve the model --------------------------------------------------
    let entry = match resolve_model(&head, &body, &router.registry) {
        Ok(Some(id)) => match router.registry.lookup(&id) {
            Some(entry) => Ok((id, entry)),
            None => Err((
                404u16,
                "invalid_request_error",
                format!("Model {id} is not in the registry"),
            )),
        },
        Ok(None) => Err((
            400u16,
            "invalid_request_error",
            "No model specified and no default configured".into(),
        )),
        Err(err) => Err((500u16, "server_error", err.to_string())),
    };
    let (model_id, entry) = match entry {
        Ok(resolved) => resolved,
        Err((status, kind, message)) => {
            http::write_error(conn, status, kind, &message)?;
            return Ok(false); // an error answer closes the connection
        }
    };

    // A chat request aimed at an embeddings-only model is a client or registry mistake; say so
    // instead of relaying it and surfacing a confusing backend 404.
    if !router.registry.serves_route(entry, head.target()) {
        http::write_error(
            conn,
            400,
            "invalid_request_error",
            &format!(
                "Model {} does not serve {}; it declares [{}]",
                entry.id,
                // Report the route only: echoing the whole target would repeat the client's own
                // ?model= back at them.
                route_path(head.target()),
                entry.capabilities.join(", ")
            ),
        )?;
        return Ok(false);
    }

    // --- make sure it is resident ------------------------------------------
    let workload = Workload {
        paths: cfg.paths.clone(),
        runner: cfg.runner.clone(),
        health_paths: cfg.health_paths.clone(),
        startup_timeout: cfg.startup_timeout,
    };
    if let Err(fail) = workload.ensure(entry, false) {
        http::write_error(conn, fail.status, fail.kind, &fail.message)?;
        return Ok(false);
    }

    // --- backend connection: pooled warm socket, or a fresh one -------------
    let backend_addr = resolve_backend_addr(entry)
        .map_err(|fail| io::Error::other(fail.message))?;
    let mut backend = match router.pool.take(entry) {
        Some(existing) => existing,
        None => {
            let tcp = TcpStream::connect_timeout(&backend_addr, cfg.connect_timeout)?;
            Stream::Tcp(tcp)
        }
    };
    backend.set_timeouts(cfg.backend_read, cfg.backend_write)?;
    backend.set_nodelay()?;

    // --- forward the request ------------------------------------------------
    // We always re-frame the body we already hold (`Content-Length`), which also covers a
    // chunked request whose framing we unwound while scanning it.
    let client_reuse_requested = !head.wants_close();
    let outbound_framing = if body.is_empty() {
        Framing::None
    } else {
        Framing::Length(body.len() as u64)
    };
    let mut out = Vec::with_capacity(1024 + body.len());
    http::write_relay_request(
        &mut out,
        &head,
        &backend_addr.to_string(),
        outbound_framing,
        // Only ask the backend to keep its socket if we can actually reuse it ourselves.
        client_reuse_requested,
    )?;
    out.extend_from_slice(&body);
    backend.write_all(&out)?;
    backend.flush()?;

    // --- read the response head, forward it, then stream the body ----------
    let mut resp_head_raw = Vec::with_capacity(1024);
    let mut resp_prefix: Vec<u8> = Vec::new();
    if !read_response_head(&mut backend, &mut resp_head_raw, &mut resp_prefix)? {
        // Backend died without answering (it was likely just stopped by a workload switch).
        // Do not poison the pool with it.
        router.pool.evict(entry);
        http::write_error(
            conn,
            502,
            "bad_gateway",
            &format!("Backend for model {} closed without responding", model_id),
        )?;
        return Ok(false);
    }
    let resp_head = match http::parse_head(&resp_head_raw) {
        Ok(Some(head)) => head,
        _ => {
            router.pool.evict(entry);
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("backend for {} sent a malformed response head", entry.id),
            ));
        }
    };
    let resp_framing = resp_head.response_framing(head.method_is(b"HEAD"));
    let client_reuse = client_reuse_requested && !resp_head.wants_close();

    http::write_relay_response(conn, &resp_head, resp_framing, client_reuse)?;

    match resp_framing {
        Framing::None => {}
        Framing::Length(len) => relay_length(&mut backend, conn, len, &mut resp_prefix)?,
        Framing::Chunked => relay_chunked(&mut backend, conn, &mut resp_prefix)?,
        Framing::UntilEof => relay_until_eof(&mut backend, conn, &mut resp_prefix)?,
    }
    conn.flush()?;

    // --- hand the backend socket back only if it is still usable -----------
    if client_reuse {
        router.pool.put(entry, backend);
    } else {
        drop(backend);
    }

    eprintln!(
        // Engine and capability list belong in the journal line: when a request goes to the
        // wrong runner, `engine=kyojin` next to a `/v1/embeddings` target is the whole answer.
        "switcher: {} {} -> {} [{}] in {:.1}ms",
        String::from_utf8_lossy(head.method()),
        String::from_utf8_lossy(head.target()),
        entry.id,
        if entry.engine.is_empty() {
            "?".to_string()
        } else {
            entry.engine.clone()
        },
        started.elapsed().as_secs_f64() * 1000.0
    );
    Ok(client_reuse)
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

/// Everything a worker needs, shared behind one `Arc` so cloning per connection is a single
/// refcount bump instead of a struct copy.
struct Router {
    config: Config,
    registry: Registry,
    pool: Pool,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let config = Config::from_args(args)?;

    // Pool sizing comes from the config, so build it before moving the config in.
    let pool = Pool::new(config.pool_max, config.pool_idle);
    let registry = config.registry.clone();
    let router = Arc::new(Router {
        config,
        registry,
        pool,
    });

    // Bind every listener **on the main thread**: a bind failure must abort startup loudly
    // (systemd restarts forever on a bad socket path), and the accept loop must own the very
    // socket that was bound - binding again inside the loop would leave the first one as a
    // deaf backlog that accepts nothing.
    let mut handles = Vec::new();
    for listen in router.config.listen.clone() {
        let listener = match listener_for(&listen, &router.config) {
            Ok(listener) => listener,
            Err(err) => {
                eprintln!("switcher: cannot bind {}: {err}", listen_label(&listen));
                return Err(Box::new(err));
            }
        };
        eprintln!(
            "switcher: listening on {} with {} registry entries",
            listener.local_addr(),
            router.registry.len()
        );
        let router = Arc::clone(&router);
        handles.push(thread::spawn(move || accept_loop(listener, router)));
    }

    for handle in handles {
        let _ = handle.join();
    }
    Ok(())
}

/// Accept until the listener dies. A parked `accept()` costs zero CPU, which is what keeps an
/// idle gateway at zero cycles; each connection gets its own thread and blocks on its own
/// sockets, so no readiness poller is needed.
fn accept_loop(listener: crate::stream::Listener, router: Arc<Router>) {
    // Counts live workers so the configured ceiling can be enforced *before* spawning, which is
    // the only point where a fresh socket is still available to answer 503 on.
    let workers = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    loop {
        match listener.accept() {
            Ok((mut stream, peer)) => {
                let limit = router.config.worker_max;
                if workers.fetch_add(1, std::sync::atomic::Ordering::Relaxed) >= limit {
                    workers.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
                    eprintln!("switcher: at the {limit} connection limit, refusing {peer}");
                    let _ = http::write_error(
                        &mut stream,
                        503,
                        "server_error",
                        "gateway is at its connection limit",
                    );
                    continue;
                }
                let router = Arc::clone(&router);
                let worker_slot = Arc::clone(&workers);
                // Clone what the failure path still needs, because the closure takes ownership
                // of `stream` and `peer` on success.
                let spawn_peer = peer.clone();
                match thread::Builder::new()
                    .stack_size(router.config.worker_stack)
                    .spawn(move || {
                        if let Err(err) = handle_connection(stream, &router) {
                            eprintln!("switcher: {peer}: connection ended: {err}");
                        }
                        worker_slot.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
                    })
                {
                    Ok(_) => {}
                    Err(err) => {
                        workers.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
                        eprintln!("switcher: cannot spawn worker for {spawn_peer}: {err}");
                    }
                }
            }
            Err(err) => {
                // EMFILE/ENFILE are transient; anything else means the listener is gone.
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                eprintln!("switcher: accept failed: {err}");
                break;
            }
        }
    }
}

fn listen_label(listen: &Listen) -> String {
    match listen {
        Listen::Unix(path) => format!("unix:{}", path.display()),
        Listen::Tcp(addr) => format!("tcp:{addr}"),
    }
}

fn listener_for(listen: &Listen, cfg: &Config) -> Result<crate::stream::Listener, std::io::Error> {
    match listen {
        Listen::Unix(path) => crate::stream::Listener::bind_unix(path, cfg.socket_mode),
        Listen::Tcp(addr) => crate::stream::Listener::bind_tcp(*addr),
    }
}

// ---------------------------------------------------------------------------
// resolve the requested model
// ---------------------------------------------------------------------------

/// Find the model a request names, in priority order:
/// 1. `?model=...` query parameter (percent-decoded)
/// 2. `X-Model: ...` header
/// 3. JSON / multipart / form body top-level `model` field
/// 4. registry default (`@default` directive)
///
/// Returns `Ok(None)` when nothing was found and no default is configured.
fn resolve_model(head: &http::Head, body: &[u8], registry: &Registry) -> Result<Option<String>, Box<dyn std::error::Error>> {
    // 1. Query string
    let mut decoded = Vec::new();
    if let Some(model) = crate::scan::query(head.target(), &mut decoded) {
        return Ok(Some(String::from_utf8_lossy(model).to_string()));
    }

    // 2. X-Model header
    if let Some(header_val) = head.header("x-model") {
        let model = String::from_utf8_lossy(header_val).trim().to_string();
        if !model.is_empty() {
            return Ok(Some(model));
        }
    }

    // 3. Body scan. Whether the value is percent-encoded depends on the envelope: JSON and
    // multipart carry it literally, form bodies encode it (and use '+' for space).
    if !body.is_empty() {
        let content_type = head.header("content-type");
        if let Some((source, hit)) = crate::scan::body(content_type, body, true) {
            if let crate::scan::Hit::Found(range) = hit {
                let raw = &body[range];
                let needs_decode = match source {
                    crate::scan::Source::Form => raw.iter().any(|&b| b == b'%' || b == b'+'),
                    _ => raw.contains(&b'%'),
                };
                let plus_as_space = matches!(source, crate::scan::Source::Form);
                let model = if needs_decode {
                    let mut buf = Vec::new();
                    crate::scan::percent_decode(raw, plus_as_space, &mut buf);
                    String::from_utf8_lossy(&buf).into_owned()
                } else {
                    String::from_utf8_lossy(raw).into_owned()
                };
                let model = model.trim();
                if !model.is_empty() {
                    return Ok(Some(model.to_string()));
                }
            }
        }
    }

    // 4. Default
    Ok(registry.default.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn head(target: &[u8], content_type: Option<&str>, body_text: &str) -> (http::Head, Vec<u8>) {
        let mut raw = format!("POST {} HTTP/1.1\r\nHost: h\r\n", String::from_utf8_lossy(target));
        if let Some(ct) = content_type {
            raw += &format!("Content-Type: {ct}\r\n");
        }
        raw += &format!("Content-Length: {}\r\n\r\n", body_text.len());
        raw += body_text;
        let bytes = raw.as_bytes();
        // find_head_end reports where the blank line *starts*; the body begins after it.
        let end = http::find_head_end(bytes).expect("head terminator") + 4;
        let head = http::parse_head(bytes).expect("head parses").expect("complete");
        (head, bytes[end..].to_vec())
    }

    fn registry() -> Registry {
        Registry::parse(concat!(
            "@default\tdefault-model\n",
            "gpu\tdefault-model\td.service\tdefault-model\thttp://127.0.0.1:1\t\tgufo\tchat\n",
            "gpu\tplain-id\tp.service\tplain-id\thttp://127.0.0.1:2\t\tllama-cpp\tchat,completions\n",
            "gpu\tspaced id\ts.service\tspaced id\thttp://127.0.0.1:3\t\tkyojin\tchat\n",
            "gpu\tplus+id\tq.service\tplus+id\thttp://127.0.0.1:4\t\tkyojin\tchat\n",
            "gpu\tembed-only\te.service\tembed-only\thttp://127.0.0.1:5\t\tnpu-embeddings\tembeddings\n",
        ))
        .unwrap()
    }

    #[test]
    fn resolves_model_from_every_transport() {
        let reg = registry();

        // Query parameter wins over the body.
        let (h, b) = head(b"/v1/chat?model=plain-id", Some("application/json"), r#"{"model":"default-model"}"#);
        assert_eq!(resolve_model(&h, &b, &reg).unwrap().as_deref(), Some("plain-id"));

        // X-Model header beats the body but loses to the query.
        let raw = b"POST /v1/chat/completions HTTP/1.1\r\nHost: h\r\nX-Model: plain-id\r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{\"model\":\"default-model\"}";
        let end = http::find_head_end(raw).unwrap() + 4;
        let h = http::parse_head(raw).unwrap().unwrap();
        assert_eq!(
            resolve_model(&h, &raw[end..], &reg).unwrap().as_deref(),
            Some("plain-id")
        );

        // JSON body.
        let (h, b) = head(b"/v1/chat/completions", Some("application/json"), r#"{"model":"plain-id"}"#);
        assert_eq!(resolve_model(&h, &b, &reg).unwrap().as_deref(), Some("plain-id"));

        // Form body, both literal and encoded (with '+' meaning space here).
        let (h, b) = head(b"/v1/embeddings", Some("application/x-www-form-urlencoded"), "model=plain-id&input=hi");
        assert_eq!(resolve_model(&h, &b, &reg).unwrap().as_deref(), Some("plain-id"));
        let (h, b) = head(
            b"/v1/chat/completions",
            Some("application/x-www-form-urlencoded"),
            "model=spaced%20id",
        );
        assert_eq!(resolve_model(&h, &b, &reg).unwrap().as_deref(), Some("spaced id"));

        // Multipart part header ordering must not confuse the scanner.
        let mp = concat!(
            "--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nplain-id\r\n",
            "--B\r\nContent-Disposition: form-data; name=\"file\"\r\n\r\nbinary\r\n--B--\r\n"
        );
        let (h, b) = head(b"/v1/chat/completions", Some("multipart/form-data; boundary=B"), mp);
        assert_eq!(resolve_model(&h, &b, &reg).unwrap().as_deref(), Some("plain-id"));

        // Nothing names a model: the default applies.
        let (h, b) = head(b"/v1/chat/completions", Some("application/json"), r#"{"prompt":"hi"}"#);
        assert_eq!(resolve_model(&h, &b, &reg).unwrap().as_deref(), Some("default-model"));
    }

    #[test]
    fn plus_in_a_uri_query_is_not_a_space() {
        let reg = registry();
        // A registry id containing '+' must be reachable through ?model= (literal '+') and
        // through %2B. Neither may resolve to "spaced id".
        let (h, b) = head(b"/v1/chat/completions?model=plus%2Bid", None, "");
        assert_eq!(resolve_model(&h, &b, &reg).unwrap().as_deref(), Some("plus+id"));
        let (h, b) = head(b"/v1/chat/completions?model=plus+id", None, "");
        assert_eq!(resolve_model(&h, &b, &reg).unwrap().as_deref(), Some("plus+id"));
    }
}

// ---------------------------------------------------------------------------
// head / body reading
// ---------------------------------------------------------------------------

/// A buffered client socket.
///
/// Every `read()` from the kernel can hand us several messages at once (a keep-alive client
/// with data already in flight, or a pipelined batch). The buffer is the single place those
/// surplus bytes live, which is what lets one connection serve many requests without losing or
/// duplicating a byte.
struct BufReader {
    stream: Stream,
    buf: Vec<u8>,
    /// Offset of the next unread byte inside `buf`.
    start: usize,
}

impl BufReader {
    fn new(stream: Stream) -> BufReader {
        BufReader {
            stream,
            buf: Vec::with_capacity(16 * 1024),
            start: 0,
        }
    }

    fn unparsed(&self) -> &[u8] {
        &self.buf[self.start..]
    }

    /// Pull more bytes off the wire into the buffer. `Ok(false)` means the peer closed.
    fn fill(&mut self) -> io::Result<bool> {
        // Drop what has already been consumed instead of growing forever on a long-lived
        // nginx connection.
        if self.start > 0 {
            if self.start == self.buf.len() {
                self.buf.clear();
            } else {
                self.buf.drain(..self.start);
            }
            self.start = 0;
        }
        let mut scratch = [0u8; 16 * 1024];
        loop {
            match self.stream.read(&mut scratch) {
                Ok(0) => return Ok(false),
                Ok(n) => {
                    self.buf.extend_from_slice(&scratch[..n]);
                    return Ok(true);
                }
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) => return Err(err),
            }
        }
    }

    /// Read exactly `len` body bytes.
    fn read_exact_into(&mut self, out: &mut Vec<u8>, len: u64) -> io::Result<()> {
        out.clear();
        if len == 0 {
            return Ok(());
        }
        out.reserve(len as usize);
        let mut left = len;
        while left > 0 {
            let available = self.unparsed();
            if available.is_empty() {
                if !self.fill()? {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "client closed before sending the promised body length",
                    ));
                }
                continue;
            }
            let take = available.len().min(left as usize);
            out.extend_from_slice(&available[..take]);
            self.start += take;
            left -= take as u64;
        }
        Ok(())
    }

    /// Unwind a `Transfer-Encoding: chunked` request body into its payload. The relay re-frames
    /// it with a plain `Content-Length`, so only the decoded bytes are needed.
    fn read_chunked_body(&mut self, out: &mut Vec<u8>, max_body: usize) -> io::Result<()> {
        out.clear();
        let mut tracker = crate::relay::Chunked::new();
        while !tracker.done() {
            if self.unparsed().is_empty() && !self.fill()? {
                break;
            }
            let consumed_here = {
                let data = self.unparsed();
                tracker.feed(data, Some(out));
                data.len()
            };
            self.start += consumed_here;
            if out.len() > max_body {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("chunked request body exceeds the {max_body} byte limit"),
                ));
            }
        }
        Ok(())
    }

    /// Read one request head. `Ok(None)` is a clean EOF at a message boundary - the normal way
    /// a keep-alive connection ends.
    fn read_head(&mut self, max_header: usize) -> io::Result<Option<http::Head>> {
        loop {
            match http::parse_head(self.unparsed()) {
                Ok(Some(head)) => {
                    let consumed = head.consumed;
                    if consumed > self.start + self.unparsed().len() {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "internal: head consumed more than was buffered",
                        ));
                    }
                    // Advance past the head; anything left stays buffered for the body.
                    self.start += consumed;
                    return Ok(Some(head));
                }
                Ok(None) => {}
                Err(msg) => return Err(io::Error::new(io::ErrorKind::InvalidData, msg)),
            }
            if self.unparsed().len() > max_header {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "request header is too large",
                ));
            }
            if !self.fill()? {
                if self.unparsed().is_empty() {
                    return Ok(None); // clean close between requests
                }
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "client closed mid-head",
                ));
            }
        }
    }
}

impl Write for BufReader {
    /// Responses go straight to the socket: nothing we write is ever read back.
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.stream.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.stream.flush()
    }
}

impl Read for BufReader {
    /// Used by the response relays when pushing bytes onward is expressed as a `Read` source.
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.stream.read(buf)
    }
}

/// Read an HTTP response head from the backend into `head_out`, returning any body bytes that
/// arrived in the same read via `body_out`. Returns false when the backend closed before
/// answering.
fn read_response_head(
    stream: &mut Stream,
    head_out: &mut Vec<u8>,
    body_out: &mut Vec<u8>,
) -> io::Result<bool> {
    head_out.clear();
    body_out.clear();
    let mut buf: Vec<u8> = Vec::with_capacity(1024);
    let mut scratch = [0u8; 8192];
    loop {
        let got = match stream.read(&mut scratch) {
            Ok(0) => return Ok(false),
            Ok(n) => n,
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        };
        buf.extend_from_slice(&scratch[..got]);
        if let Some(end) = http::find_head_end(&buf) {
            let head_len = end + 4;
            head_out.extend_from_slice(&buf[..head_len]);
            if buf.len() > head_len {
                *body_out = buf.split_off(head_len);
            }
            return Ok(true);
        }
        if buf.len() > 64 * 1024 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "response head is too large",
            ));
        }
    }
}

// ---------------------------------------------------------------------------
// response body forwarding
// ---------------------------------------------------------------------------

/// A source that yields the bytes buffered alongside the response head first, then keeps
/// reading the socket. Without this, the first body segment would be sent twice or lost.
struct Prefixed<'a> {
    stream: &'a mut Stream,
    prefix: &'a [u8],
}

impl Read for Prefixed<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if !self.prefix.is_empty() {
            let n = self.prefix.len().min(buf.len());
            buf[..n].copy_from_slice(&self.prefix[..n]);
            self.prefix = &self.prefix[n..];
            return Ok(n);
        }
        self.stream.read(buf)
    }
}

/// Forward exactly `len` body bytes.
fn relay_length<W: Write>(
    backend: &mut Stream,
    client: &mut W,
    len: u64,
    prefix: &mut Vec<u8>,
) -> io::Result<()> {
    if len == 0 {
        return Ok(());
    }
    let mut src = Prefixed { stream: backend, prefix };
    let mut buf = vec![0u8; 64 * 1024];
    let mut left = len;
    while left > 0 {
        let want = left.min(buf.len() as u64) as usize;
        let got = match src.read(&mut buf[..want]) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "backend closed before the promised body length",
                ))
            }
            Ok(n) => n,
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        };
        client.write_all(&buf[..got])?;
        left -= got as u64;
    }
    Ok(())
}

/// Forward a chunked body **verbatim** (framing included) until the terminating zero-length
/// chunk, flushing per read so SSE tokens reach the client as they are produced.
fn relay_chunked<W: Write>(
    backend: &mut Stream,
    client: &mut W,
    prefix: &mut Vec<u8>,
) -> io::Result<()> {
    let mut src = Prefixed { stream: backend, prefix };
    let mut buf = vec![0u8; 64 * 1024];
    let mut tracker = crate::relay::Chunked::new();
    loop {
        let got = match src.read(&mut buf) {
            Ok(0) => return Ok(()),
            Ok(n) => n,
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        };
        client.write_all(&buf[..got])?;
        client.flush()?;
        if tracker.feed(&buf[..got], None) {
            return Ok(());
        }
    }
}

/// Forward an unframed body until the backend closes.
fn relay_until_eof<W: Write>(
    backend: &mut Stream,
    client: &mut W,
    prefix: &mut Vec<u8>,
) -> io::Result<()> {
    let mut src = Prefixed { stream: backend, prefix };
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let got = match src.read(&mut buf) {
            Ok(0) => return Ok(()),
            Ok(n) => n,
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        };
        client.write_all(&buf[..got])?;
        client.flush()?;
    }
}

#[cfg(test)]
mod e2e_units {
    use crate::http::*;
    #[test]
    fn response_head_round_trip() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n";
        let h = parse_head(raw).unwrap().unwrap();
        // On a response the version is token 0; `version()` (token 2) is the reason phrase.
        assert_eq!(h.response_version(), b"HTTP/1.1");
        assert_eq!(h.version(), b"OK");
        assert_eq!(h.status(), 200);
        let mut out = Vec::new();
        write_relay_response(&mut out, &h, Framing::Length(2), true).unwrap();
        let text = String::from_utf8(out).unwrap();
        println!("RELAYED HEAD:\n{text}");
        assert!(text.starts_with("HTTP/1.1 200 OK\r\n"), "got: {text:?}");
    }
}

/// The path portion of a request target, without its query string, as `String`.
fn route_path(target: &[u8]) -> String {
    let end = target.iter().position(|&b| b == b'?').unwrap_or(target.len());
    String::from_utf8_lossy(&target[..end]).into_owned()
}
