//! Model registry: the deserialization of the file Nix generates at build time.
//!
//! The wire format is intentionally **not** JSON. The registry is emitted by
//! `../default.nix` from `config.services.models`, i.e. it is machine-written and machine-read
//! inside one repo, so it uses a flat tab-separated format the router can parse with zero
//! dependencies and zero ambiguity:
//!
//! ```text
//! # comment lines start with '#'
//! @default<TAB>qwen3.8-flash-next
//! devices<TAB>id<TAB>service<TAB>remapped<TAB>url<TAB>model_dir<TAB>engine<TAB>capabilities
//! gpu     <TAB>foo <TAB>gufo-foo.service <TAB>foo <TAB>http://127.0.0.1:8081 <TAB> <TAB>gufo <TAB>chat,completions
//! ```
//!
//! * `devices` is a comma separated list (`gpu`, `npu`, `gpu,npu`). One day a model may need
//!   both accelerators - the router already acquires every listed domain's lock, in the
//!   canonical order [`Device::LOCK_ORDER`], so no cross-domain deadlock can arise.
//! * `\t`, `\n` and `\\` inside a field are escaped as `\\t`, `\\n`, `\\\\`.
//! * `@default` is the model to serve when a request names none; the value is empty when
//!   `services.defaultModel = null` (boot with nothing resident).

use std::collections::HashMap;
use std::fmt;

/// A hardware domain with its own lock, its own state file and its own conflict set.
///
/// Declaration order **is** the lock acquisition order: `Gpu` before `Npu`. Any future model
/// that needs both accelerators takes them in this order, and every other orchestrator
/// (`stop-other-workloads`, the wake scripts) only ever holds one at a time, so the wait-for
/// graph stays a line instead of becoming a cycle.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Hash)]
pub enum Device {
    Gpu,
    Npu,
}

impl Device {
    /// Canonical order for multi-domain models - never sort by name at runtime, sort by this.
    pub const LOCK_ORDER: [Device; 2] = [Device::Gpu, Device::Npu];

    pub fn as_str(self) -> &'static str {
        match self {
            Device::Gpu => "gpu",
            Device::Npu => "npu",
        }
    }

    pub fn parse(s: &str) -> Option<Device> {
        match s.trim() {
            "gpu" => Some(Device::Gpu),
            "npu" => Some(Device::Npu),
            _ => None,
        }
    }
}

impl fmt::Display for Device {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One inference workload: one systemd unit, one loopback HTTP backend, one process.
#[derive(Clone)]
pub struct Entry {
    /// Domains this model occupies. A model is "resident" only when **every** domain's state
    /// file names it, and switching it means locking all of them.
    pub devices: Vec<Device>,
    /// Registry key - what clients put in `{"model": ...}`.
    pub id: String,
    /// systemd unit that owns the process.
    pub service: String,
    /// The name the backend itself expects; `Some(span)` rewrites only when this differs.
    pub remapped: String,
    pub host: String,
    pub port: u16,
    /// Weights directory, pre-flighted before a (possibly minutes-long) unit start.
    pub model_dir: String,
    pub engine: String,
    pub capabilities: Vec<String>,
}

impl Entry {
    /// The single device today; kept as a helper so single-domain call sites stay readable.


    pub fn authority(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}

#[derive(Clone)]
pub struct Registry {
    pub default: Option<String>,
    entries: Vec<Entry>,
    /// registry key -> index into `entries`
    by_id: HashMap<String, u32>,
    /// backend-side name -> index, so a client may address `Llama-3.2-1B-Instruct_rai_1.9.0_npu`
    by_alias: HashMap<String, u32>,
}

impl Registry {
    pub fn parse(text: &str) -> Result<Registry, String> {
        let mut default: Option<String> = None;
        let mut entries: Vec<Entry> = Vec::new();
        let mut by_id: HashMap<String, u32> = HashMap::new();
        let mut by_alias: HashMap<String, u32> = HashMap::new();

        for (no, line) in text.lines().enumerate() {
            let line = line.strip_suffix('\r').unwrap_or(line);
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let fields: Vec<String> = line.split('\t').map(unescape).collect();

            if let Some(directive) = line.strip_prefix('@') {
                let mut it = directive.split('\t');
                let key = it.next().unwrap_or("");
                if key == "default" {
                    let value = it.next().unwrap_or("").trim().to_string();
                    if !value.is_empty() {
                        default = Some(value);
                    }
                }
                continue;
            }

            // devices, id, service, remapped, url  (the rest is optional metadata)
            if fields.len() < 5 {
                return Err(format!("line {}: expected at least 5 tab-separated fields", no + 1));
            }
            let devices = parse_devices(&fields[0])
                .ok_or_else(|| format!("line {}: unknown device domain {:?}", no + 1, fields[0]))?;
            let id = fields[1].clone();
            if id.is_empty() {
                return Err(format!("line {}: empty model id", no + 1));
            }
            let (host, port) = split_authority(&fields[4])
                .ok_or_else(|| format!("line {}: unsupported backend url {:?}", no + 1, fields[4]))?;
            let entry = Entry {
                devices,
                service: fields[2].clone(),
                id: id.clone(),
                remapped: if fields[3].is_empty() { id.clone() } else { fields[3].clone() },
                host,
                port,
                model_dir: fields.get(5).cloned().unwrap_or_default(),
                engine: fields.get(6).cloned().unwrap_or_default(),
                capabilities: fields
                    .get(7)
                    .map(|c| {
                        c.split(',')
                            .map(str::trim)
                            .filter(|s| !s.is_empty())
                            .map(str::to_string)
                            .collect()
                    })
                    .unwrap_or_default(),
            };
            let idx = entries.len() as u32;
            if by_id.insert(id.clone(), idx).is_some() {
                return Err(format!("line {}: duplicate model id {:?}", no + 1, id));
            }
            // An alias that collides with a real registry key must never shadow it.
            by_alias.entry(entry.remapped.clone()).or_insert(idx);
            entries.push(entry);
        }

        Ok(Registry {
            default,
            entries,
            by_id,
            by_alias,
        })
    }

    /// Resolve a name a client used. Registry keys win over backend aliases.
    pub fn lookup(&self, name: &str) -> Option<&Entry> {
        self.by_id
            .get(name)
            .or_else(|| self.by_alias.get(name))
            .map(|&i| &self.entries[i as usize])
    }

    /// Whether `entry`'s runner claims to serve the route this request targets.
    ///
    /// A warning rather than a refusal: the registry is declarative and a capability list can
    /// legitimately lag behind a runner, so refusing outright would turn a stale Nix entry into
    /// an outage. The mismatch is logged instead - pointing a chat request at an embeddings-only
    /// model is otherwise silent until the backend 404s.
    pub fn serves_route(&self, entry: &Entry, target: &[u8]) -> bool {
        if entry.capabilities.is_empty() {
            return true; // nothing declared: the runner decides
        }
        let route = match target.iter().position(|&b| b == b'?') {
            Some(q) => &target[..q],
            None => target,
        };
        // Map the OpenAI route onto a capability name. Order matters twice over:
        // `/v1/chat/completions` also ends with `/completions`, so the more specific suffix must
        // be tested first, or a chat-only model would be refused for a chat request.
        let wanted = if route.ends_with(b"/embeddings") {
            "embeddings"
        } else if route.ends_with(b"/rerank") {
            "rerank"
        } else if route.ends_with(b"/chat/completions") {
            // Chat is served by anything that speaks either of these; runners rarely expose one
            // without the other, and refusing here would break real clients.
            "chat"
        } else if route.ends_with(b"/completions") {
            "completions"
        } else if route.ends_with(b"/audio/speech") || route.ends_with(b"/transcriptions") {
            "audio"
        } else if route.ends_with(b"/images/generations") {
            "images"
        } else {
            return true; // unknown route: not ours to judge
        };
        // A runner that declares chat but not completions (or vice versa) still serves both
        // shapes in practice, so treat them as one family before rejecting.
        if wanted == "chat" || wanted == "completions" {
            return entry
                .capabilities
                .iter()
                .any(|c| c == "chat" || c == "completions");
        }
        entry.capabilities.iter().any(|c| c == wanted)
    }



    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

fn parse_devices(spec: &str) -> Option<Vec<Device>> {
    let mut out = Vec::with_capacity(2);
    for part in spec.split(',') {
        match Device::parse(part) {
            Some(d) if !out.contains(&d) => out.push(d),
            Some(_) => {}
            None => return None,
        }
    }
    if out.is_empty() {
        return None;
    }
    // Canonical order regardless of how Nix emitted the list.
    out.sort();
    Some(out)
}

/// `http://127.0.0.1:8081` (with an optional path suffix) -> `("127.0.0.1", 8081)`.
fn split_authority(url: &str) -> Option<(String, u16)> {
    let rest = url
        .strip_prefix("http://")
        .or_else(|| url.strip_prefix("HTTP://"))?;
    let authority = rest.split(['/', '?']).next()?;
    if authority.is_empty() {
        return None;
    }
    match authority.rsplit_once(':') {
        Some((host, port)) => Some((host.to_string(), port.parse().ok()?)),
        None => Some((authority.to_string(), 80)),
    }
}

/// Undo the escaping `../default.nix` applies to every field.
fn unescape(field: &str) -> String {
    if !field.contains('\\') {
        return field.to_string();
    }
    let mut out = String::with_capacity(field.len());
    let mut chars = field.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('t') => out.push('\t'),
            Some('n') => out.push('\n'),
            Some('\\') => out.push('\\'),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan;

    const SAMPLE: &str = concat!(
        "# generated\n",
        "@default\tqwen2.5-72b-instruct\n",
        "gpu\tqwen2.5-72b-instruct\tgufo-a.service\tqwen2.5-72b-instruct\thttp://127.0.0.1:8081\t\tgufo\tchat,completions\n",
        "npu\tllama-3.2-1b-npu\tnpu-llama.service\tLlama-3.2-1B-Instruct_rai_1.9.0_npu\thttp://127.0.0.1:8083\t/srv/models/x\tnpu-genai\tchat\n",
        "gpu,npu\thybrid.service-ish\thybrid.service\thybrid\thttp://127.0.0.1:8090\t\thybrid\t\n",
    );

    #[test]
    fn parses_registry() {
        let r = Registry::parse(SAMPLE).expect("parses");
        assert_eq!(r.len(), 3);
        assert_eq!(r.default.as_deref(), Some("qwen2.5-72b-instruct"));
        assert_eq!(r.lookup("qwen2.5-72b-instruct").unwrap().port, 8081);
        assert_eq!(r.lookup("qwen2.5-72b-instruct").unwrap().devices, vec![Device::Gpu]);
        assert_eq!(
            r.lookup("llama-3.2-1b-npu").unwrap().remapped,
            "Llama-3.2-1B-Instruct_rai_1.9.0_npu"
        );
        assert_eq!(
            r.lookup("hybrid.service-ish").unwrap().devices,
            vec![Device::Gpu, Device::Npu]
        );
        assert_eq!(r.lookup("Llama-3.2-1B-Instruct_rai_1.9.0_npu").unwrap().id, "llama-3.2-1b-npu");
        assert!(r.lookup("nope").is_none());
    }

    #[test]
    fn device_list_is_canonically_ordered_and_deduped() {
        assert_eq!(parse_devices("npu,gpu").unwrap(), vec![Device::Gpu, Device::Npu]);
        assert_eq!(parse_devices("npu,npu").unwrap(), vec![Device::Npu]);
        assert!(parse_devices("tpu").is_none());
        assert!(parse_devices("").is_none());
    }

    #[test]
    fn escapes_round_trip() {
        assert_eq!(unescape("a\\tb"), "a\tb");
        assert_eq!(unescape("a\\nb"), "a\nb");
        assert_eq!(unescape("a\\\\b"), "a\\b");
        assert_eq!(unescape("plain"), "plain");
    }

    #[test]
    fn authority_parsing() {
        assert_eq!(split_authority("http://127.0.0.1:8081"), Some(("127.0.0.1".into(), 8081)));
        assert_eq!(split_authority("http://localhost:9/v1"), Some(("localhost".into(), 9)));
        assert_eq!(split_authority("http://h"), Some(("h".into(), 80)));
        assert_eq!(split_authority("https://h:1"), None);
        assert_eq!(split_authority("h:1"), None);
    }


    #[test]
    fn route_checks_use_declared_capabilities() {
        let reg = Registry::parse(
            concat!(
                "gpu\tg\tsvc-g.service\tg\thttp://127.0.0.1:1\t\tgufo\tchat,completions\n",
                "gpu\te\tsvc-e.service\te\thttp://127.0.0.1:2\t\tnpu-embeddings\tembeddings\n",
                "gpu\tf\tsvc-f.service\tf\thttp://127.0.0.1:3\t\topenai-compatible\t\n",
            ),
        )
        .unwrap();
        let chat = reg.lookup("g").unwrap();
        let emb = reg.lookup("e").unwrap();
        let anything = reg.lookup("f").unwrap();

        assert!(reg.serves_route(chat, b"/v1/chat/completions"));
        assert!(reg.serves_route(chat, b"/v1/completions?x=1"));
        assert!(!reg.serves_route(chat, b"/v1/embeddings"));

        // Regression: `/v1/chat/completions` also ends with `/completions`. Matching that first
        // refused every chat-only model for plain chat requests.
        let reg_chat_only = Registry::parse(concat!(
            "gpu\tc\tc.service\tc\thttp://127.0.0.1:1\t\tnpu-genai\tchat\n",
        ))
        .unwrap();
        let chat_only = reg_chat_only.lookup("c").unwrap();
        assert!(reg.serves_route(chat_only, b"/v1/chat/completions"));
        assert!(reg.serves_route(chat_only, b"/v1/completions"));
        assert!(!reg.serves_route(chat_only, b"/v1/embeddings"));

        assert!(reg.serves_route(emb, b"/v1/embeddings"));
        assert!(!reg.serves_route(emb, b"/v1/chat/completions"));

        // No declared capabilities: the runner decides, so nothing is blocked here.
        assert!(reg.serves_route(anything, b"/v1/chat/completions"));
        // Unknown routes are not judged at all.
        assert!(reg.serves_route(emb, b"/health"));
    }

    #[test]
    fn percent_decodes_ids() {
        // nginx forwards the target raw, so an id in a query string may arrive percent-encoded.
        let mut out = Vec::new();
        scan::percent_decode(b"a%20b", false, &mut out);
        assert_eq!(out, b"a b");
        out.clear();
        scan::percent_decode(b"%25", false, &mut out);
        assert_eq!(out, b"%");
        out.clear();
        scan::percent_decode(b"bad%zz", false, &mut out);
        assert_eq!(out, b"bad%zz");
        // "+" is a literal plus in a URI, but a space in form encoding.
        out.clear();
        scan::percent_decode(b"a+b", false, &mut out);
        assert_eq!(out, b"a+b");
        out.clear();
        scan::percent_decode(b"a+b", true, &mut out);
        assert_eq!(out, b"a b");

        let reg = Registry::parse(concat!(
            "@default\tspaced-id\tz\n",
            "gpu\tspaced-id\ty.service\tspaced-id\thttp://127.0.0.1:1\t\tx\t\n",
        ))
        .unwrap();
        // A JSON body carrying the encoded id resolves to the decoded registry key. The
        // scanner reports a byte range; the caller slices and decodes.
        let json_body = b"{\"model\":\"spaced%2Did\"}";
        let (_source, hit) = scan::body(Some(b"application/json"), json_body, true).unwrap();
        let raw = &json_body[hit.range().expect("found")];
        let mut decoded = Vec::new();
        scan::percent_decode(raw, false, &mut decoded);
        let name = String::from_utf8(decoded).unwrap();
        assert_eq!(name, "spaced-id");
        assert_eq!(reg.lookup(&name).unwrap().service, "y.service");
    }

    #[test]
    fn missing_url_is_rejected() {
        // A registry line without a usable backend URL must fail at load, not at request time.
        assert!(Registry::parse("gpu\tno-url\tsvc\tno-url\t\t\tx\t\n").is_err());
    }

    #[test]
    fn registry_key_beats_alias() {
        let sample = concat!(
            "@default\t\n",
            "gpu\ta\ta.service\tb\thttp://127.0.0.1:1\t\tx\t\n",
            "gpu\tb\tb.service\tb\thttp://127.0.0.1:2\t\tx\t\n",
        );
        let r = Registry::parse(sample).unwrap();
        // "b" is both an id and a's alias: the real registry entry must win.
        assert_eq!(r.lookup("b").unwrap().service, "b.service");
    }
}

#[cfg(test)]
mod wire_compat {
    use super::{Device, Registry};

    /// Byte-for-byte agreement with `modules/switcher/registry.nix`: that file escapes
    /// `\`, TAB, CR and LF in that order, and this parser must undo exactly it. If either side
    /// changes alone, every model with an unusual id silently disappears from routing.
    #[test]
    fn nix_escape_format_round_trips() {
        let sample = concat!(
            "# generated by modules/switcher/registry.nix - do not edit\n",
            "@default\tqwen3.8-flash-next\n",
            "gpu\tqwen3.8-flash-next\tgufo-qwen.service\tqwen3.8-flash-next\thttp://127.0.0.1:8081\t\tgufo\tchat,completions\n",
            "npu\tspaced\\ttab-model\tnpu-x.service\trai_name\thttp://127.0.0.1:8083\t/srv/models/x\tnpu-genai\t\n",
        );
        let reg = Registry::parse(sample).expect("parses");
        assert_eq!(reg.len(), 2);
        assert_eq!(reg.default.as_deref(), Some("qwen3.8-flash-next"));

        // The escaped TAB decodes back into a real one inside the id, and the line still has
        // exactly eight fields - i.e. the escape did not shift any column.
        let odd = reg.lookup("spaced\ttab-model").expect("id with a decoded tab resolves");
        assert_eq!(odd.service, "npu-x.service");
        assert_eq!(odd.remapped, "rai_name");
        assert_eq!(odd.port, 8083);
        assert_eq!(odd.model_dir, "/srv/models/x");
        assert_eq!(odd.engine, "npu-genai");
        assert_eq!(odd.devices, vec![Device::Npu]);
        assert!(odd.capabilities.is_empty());

        let gufo = reg.lookup("qwen3.8-flash-next").unwrap();
        assert_eq!(gufo.capabilities, vec!["chat", "completions"]);
        assert_eq!(gufo.model_dir, "");
    }
}
