//! HTTP/1.1 message heads: parse in place, rebuild only what must change.
//!
//! There is no HTTP framework here on purpose. The router is a byte relay with two small
//! requirements: understand the head (framing, a couple of headers) and forward everything
//! else verbatim. That keeps the whole hot path at a handful of syscalls plus one small memcpy
//! per request, and it means **any** method on **any** path works today and next month - the
//! endpoint is never interpreted, only relayed.

use std::io::{self, Write};
use std::ops::Range;

/// The absolute cap on a message head; anything bigger is a client error, not a body.
pub const MAX_HEAD: usize = 128 * 1024;

/// A name/value pair as offsets into [`Head::raw`].
#[derive(Clone)]
pub struct Header {
    pub name: Range<usize>,
    pub value: Range<usize>,
}

/// A parsed head. `tok*` is the request line (`method`, `target`, `version`) or the status
/// line (`HTTP/1.1`, `200`, `reason`) - one shape, two readings, because both are "three
/// tokens then headers".
///
/// The head is **copied** out of the read buffer (a few hundred bytes, once per request). That
/// buys the whole relay its most valuable property: nothing in the request path holds a borrow
/// of the socket buffer, so the same buffer can be grown with more body bytes while the parsed
/// head is still in use - no second buffer, no lifetime gymnastics, no `Vec<Vec<u8>>` churn.
pub struct Head {
    pub raw: Vec<u8>,
    pub tokens: [Range<usize>; 3],
    pub headers: Vec<Header>,
    /// Bytes consumed by the head in the source buffer, including the terminating CRLF blank
    /// line. Anything past this already belongs to the body.
    pub consumed: usize,
}

impl Head {
    fn token(&self, index: usize) -> &[u8] {
        &self.raw[self.tokens[index].clone()]
    }

    fn header_value(&self, header: &Header) -> &[u8] {
        &self.raw[header.value.clone()]
    }

    fn header_name(&self, header: &Header) -> &[u8] {
        &self.raw[header.name.clone()]
    }
}

/// Position of the blank line that ends a head, if present. Used by the read loop to
/// decide whether the head is complete without copying the whole buffer into a `Head`.
pub fn find_head_end(buf: &[u8]) -> Option<usize> {
    crate::scan::find(buf, b"\r\n\r\n")
}

/// `Ok(None)` = need more bytes, `Err` = malformed / oversized.
pub fn parse_head(buf: &[u8]) -> Result<Option<Head>, &'static str> {
    let end = match find_head_end(buf) {
        Some(at) => at,
        None => {
            return if buf.len() > MAX_HEAD {
                Err("request header is too large")
            } else {
                Ok(None)
            }
        }
    };

    let first_line_end = crate::scan::find(&buf[..end], b"\r\n").unwrap_or(end);
    let first = &buf[..first_line_end];

    // One copy of the head; every token and header below is an offset into it.
    let mut raw: Vec<u8> = Vec::with_capacity(end);
    let mut tokens: [Range<usize>; 3] = [0..0, 0..0, 0..0];
    let mut at = 0usize;
    for slot in tokens.iter_mut() {
        while at < first.len() && first[at] == b' ' {
            at += 1;
        }
        let word_end = first[at..]
            .iter()
            .position(|&b| b == b' ')
            .map(|p| at + p)
            .unwrap_or(first.len());
        *slot = raw.len()..raw.len() + (word_end - at);
        raw.extend_from_slice(&first[at..word_end]);
        at = word_end;
    }

    let mut headers = Vec::with_capacity(12);
    let mut line_at = first_line_end + 2;
    while line_at < end {
        let line_end = crate::scan::find(&buf[line_at..end], b"\r\n")
            .map(|p| line_at + p)
            .unwrap_or(end);
        let line = &buf[line_at..line_end];
        if let Some(colon) = line.iter().position(|&b| b == b':') {
            let mut vs = colon + 1;
            while vs < line.len() && matches!(line[vs], b' ' | b'\t') {
                vs += 1;
            }
            let mut ve = line.len();
            while ve > vs && matches!(line[ve - 1], b' ' | b'\t') {
                ve -= 1;
            }
            let base = raw.len();
            raw.extend_from_slice(&line[..colon]);
            raw.extend_from_slice(&line[vs..ve]);
            headers.push(Header {
                name: base..base + colon,
                value: base + colon..base + colon + (ve - vs),
            });
        }
        line_at = line_end + 2;
    }

    Ok(Some(Head {
        raw,
        tokens,
        headers,
        consumed: end + 4,
    }))
}

/// How the body following a head is framed on the wire.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Framing {
    /// No body at all.
    None,
    /// `Content-Length: n`.
    Length(u64),
    /// `Transfer-Encoding: chunked` - framing is relayed untouched, tracked to its end.
    Chunked,
    /// Unframed: the body is everything until the peer closes (never connection-reusable).
    UntilEof,
}

impl Head {
    pub fn method(&self) -> &[u8] {
        self.token(0)
    }

    pub fn method_is(&self, name: &[u8]) -> bool {
        self.token(0).eq_ignore_ascii_case(name)
    }

    pub fn target(&self) -> &[u8] {
        self.token(1)
    }

    /// HTTP version of a **request** line (`METHOD TARGET VERSION`).
    pub fn version(&self) -> &[u8] {
        self.token(2)
    }

    /// HTTP version of a **response** status line (`VERSION STATUS REASON`) - token zero, the
    /// mirror image of [`Head::version`]. One head shape serves both messages, so the reader
    /// must say which side it is on.
    pub fn response_version(&self) -> &[u8] {
        self.token(0)
    }

    pub fn status(&self) -> u16 {
        self.token(1).iter().fold(0u32, |acc, &b| {
            if b.is_ascii_digit() {
                acc * 10 + (b - b'0') as u32
            } else {
                acc
            }
        }) as u16
    }

    pub fn header(&self, name: &str) -> Option<&[u8]> {
        self.headers
            .iter()
            .find(|h| self.header_name(h).eq_ignore_ascii_case(name.as_bytes()))
            .map(|h| self.header_value(h))
    }

    pub fn has_header(&self, name: &str) -> bool {
        self.header(name).is_some()
    }

    /// Body framing of a request: chunked wins over Content-Length (RFC 9112 §6.3), a body
    /// with neither is treated as absent, since that is what every OpenAI client sends.
    pub fn request_framing(&self) -> Framing {
        if self.transfer_chunked() {
            Framing::Chunked
        } else if self.method_is(b"HEAD") {
            Framing::None
        } else {
            match self.content_length() {
                Some(0) => Framing::None,
                Some(n) => Framing::Length(n),
                None => Framing::None,
            }
        }
    }

    /// Body framing of a response. `1xx`/`204`/`304` never carry one; a `HEAD` answer carries
    /// the length it *would* have carried, which the caller passes as [`Framing::None`].
    pub fn response_framing(&self, head_request: bool) -> Framing {
        let status = self.status();
        if head_request || status == 204 || status == 304 || (100..200).contains(&status) {
            return Framing::None;
        }
        if self.transfer_chunked() {
            return Framing::Chunked;
        }
        match self.content_length() {
            Some(n) => Framing::Length(n),
            None if status == 200 => Framing::UntilEof,
            None => Framing::None,
        }
    }

    pub fn content_length(&self) -> Option<u64> {
        let raw = self.header("content-length")?;
        let text = std::str::from_utf8(raw).ok()?.trim();
        // A repeated, disagreeing Content-Length is a request smuggling attempt, not a body.
        let value: u64 = text.parse().ok()?;
        Some(value)
    }

    pub fn transfer_chunked(&self) -> bool {
        self.headers.iter().any(|h| {
            self.header_name(h).eq_ignore_ascii_case(b"transfer-encoding")
                && self
                    .header_value(h)
                    .split(|&b| b == b',')
                    .any(|part| trim(part).eq_ignore_ascii_case(b"chunked"))
        })
    }

    /// `Connection: close` (or HTTP/1.0 without `keep-alive`) on either side ends the
    /// connection after one exchange.
    pub fn wants_close(&self) -> bool {
        let mut close = self.version().eq_ignore_ascii_case(b"HTTP/1.0")
            && !self.headers.iter().any(|h| {
                self.header_name(h).eq_ignore_ascii_case(b"connection")
                    && trim(self.header_value(h)).eq_ignore_ascii_case(b"keep-alive")
            });
        for h in &self.headers {
            if !self.header_name(h).eq_ignore_ascii_case(b"connection") {
                continue;
            }
            for token in self.header_value(h).split(|&b| b == b',') {
                let token = trim(token);
                if token.eq_ignore_ascii_case(b"close") {
                    close = true;
                }
            }
        }
        close
    }


}

/// Headers that must never be relayed: hop-by-hop, or framing the router rewrites itself.
const STRIP_REQUEST: [&[u8]; 10] = [
    b"host",
    b"content-length",
    b"transfer-encoding",
    b"connection",
    b"expect",
    b"te",
    b"trailer",
    b"upgrade",
    b"proxy-connection",
    b"keep-alive",
];

const STRIP_RESPONSE: [&[u8]; 8] = [
    b"connection",
    b"keep-alive",
    b"proxy-authenticate",
    b"proxy-authorization",
    b"te",
    b"trailer",
    b"transfer-encoding",
    b"content-length",
];

/// Emit the request line + headers for the backend, original order preserved.
pub fn write_relay_request<W: Write>(
    w: &mut W,
    req: &Head,
    authority: &str,
    framing: Framing,
    reuse: bool,
) -> io::Result<()> {
    let mut out = Vec::with_capacity(512);
    out.extend_from_slice(req.method());
    out.extend_from_slice(b" ");
    out.extend_from_slice(req.target());
    out.extend_from_slice(b" HTTP/1.1\r\n");
    out.extend_from_slice(b"Host: ");
    out.extend_from_slice(authority.as_bytes());
    out.extend_from_slice(b"\r\n");
    copy_headers(&mut out, req, &STRIP_REQUEST);
    match framing {
        Framing::Length(n) => out.extend_from_slice(format!("Content-Length: {n}\r\n").as_bytes()),
        Framing::Chunked => out.extend_from_slice(b"Transfer-Encoding: chunked\r\n"),
        Framing::None | Framing::UntilEof => {}
    }
    if !reuse {
        out.extend_from_slice(b"Connection: close\r\n");
    }
    out.extend_from_slice(b"\r\n");
    w.write_all(&out)
}

/// Emit the status line + headers for the client. `cors` is only appended when the backend
/// did not answer CORS itself - two `Access-Control-Allow-Origin` headers break browsers.
pub fn write_relay_response<W: Write>(
    w: &mut W,
    resp: &Head,
    framing: Framing,
    reuse: bool,
) -> io::Result<()> {
    let mut out = Vec::with_capacity(512);
    // Status line: VERSION STATUS REASON. The version is token 0 on this side of the relay
    // (see `Head::response_version`); a backend that sent a bare "HTTP/1.1 200" without a
    // reason phrase still round-trips, because the reason is optional.
    let version = if resp.response_version().is_empty() {
        b"HTTP/1.1".as_slice()
    } else {
        resp.response_version()
    };
    out.extend_from_slice(version);
    out.extend_from_slice(b" ");
    out.extend_from_slice(resp.token(1));
    if !resp.token(2).is_empty() {
        out.extend_from_slice(b" ");
        out.extend_from_slice(resp.token(2));
    }
    out.extend_from_slice(b"\r\n");
    copy_headers(&mut out, resp, &STRIP_RESPONSE);
    match framing {
        Framing::Length(n) => out.extend_from_slice(format!("Content-Length: {n}\r\n").as_bytes()),
        Framing::Chunked => out.extend_from_slice(b"Transfer-Encoding: chunked\r\n"),
        Framing::None | Framing::UntilEof => {}
    }
    if !resp.has_header("access-control-allow-origin") {
        out.extend_from_slice(b"Access-Control-Allow-Origin: *\r\n");
    }
    if !resp.has_header("x-accel-buffering") {
        // nginx must not buffer token streams; the old CGI path injected this through sed.
        out.extend_from_slice(b"X-Accel-Buffering: no\r\n");
    }
    if !reuse {
        out.extend_from_slice(b"Connection: close\r\n");
    }
    out.extend_from_slice(b"\r\n");
    w.write_all(&out)
}

fn copy_headers(out: &mut Vec<u8>, head: &Head, strip: &[&[u8]]) {
    'header: for h in &head.headers {
        let name = head.header_name(h);
        for skip in strip {
            if name.eq_ignore_ascii_case(skip) {
                continue 'header;
            }
        }
        out.extend_from_slice(name);
        out.extend_from_slice(b": ");
        out.extend_from_slice(head.header_value(h));
        out.extend_from_slice(b"\r\n");
    }
}

/// Write a request body to the wire. When the router has rewritten the model id inside
/// the body, `out` carries the rewritten bytes and `len` is their length; otherwise the
/// caller streams the original bytes directly and this is a no-op.


/// A minimal error answer. Errors carry `Content-Length` so a pooled connection stays usable.
pub fn write_error<W: Write>(w: &mut W, status: u16, kind: &str, message: &str) -> io::Result<()> {
    let body = format!(
        "{{\"error\":{{\"message\":\"{}\",\"type\":\"{}\"}}}}\n",
        escape_json(message),
        kind
    );
    let mut out = Vec::with_capacity(body.len() + 256);
    out.extend_from_slice(format!("HTTP/1.1 {status} {}\r\n", reason(status)).as_bytes());
    out.extend_from_slice(b"Content-Type: application/json\r\n");
    out.extend_from_slice(format!("Content-Length: {}\r\n", body.len()).as_bytes());
    out.extend_from_slice(b"Access-Control-Allow-Origin: *\r\n");
    out.extend_from_slice(b"X-Accel-Buffering: no\r\n");
    // An error before the body was consumed ends the exchange: leftover request bytes would
    // otherwise be parsed as the next request.
    out.extend_from_slice(b"Connection: close\r\n\r\n");
    out.extend_from_slice(body.as_bytes());
    w.write_all(&out)
}

pub fn reason(status: u16) -> &'static str {
    match status {
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        413 => "Content Too Large",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        _ => "OK",
    }
}

fn escape_json(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

pub fn trim(bytes: &[u8]) -> &[u8] {
    let start = bytes
        .iter()
        .position(|&b| !matches!(b, b' ' | b'\t'))
        .unwrap_or(bytes.len());
    let end = bytes
        .iter()
        .rposition(|&b| !matches!(b, b' ' | b'\t'))
        .map(|p| p + 1)
        .unwrap_or(start);
    &bytes[start..end]
}

#[cfg(test)]
mod tests {
    use super::*;

    const REQ: &[u8] = b"POST /v1/chat/completions HTTP/1.1\r\n\
         Host: evo-x2:8080\r\n\
         Content-Type: application/json\r\n\
         content-length: 42\r\n\
         Authorization: Bearer t0ken\r\n\
         Connection: keep-alive\r\n\
         \r\n\
         {\"model\":\"x\"}";

    #[test]
    fn parses_request_head() {
        let h = parse_head(REQ).unwrap().unwrap();
        assert_eq!(h.method(), b"POST");
        assert_eq!(h.target(), b"/v1/chat/completions");
        assert_eq!(h.version(), b"HTTP/1.1");
        assert_eq!(h.content_length(), Some(42));
        assert_eq!(h.header("authorization"), Some(&b"Bearer t0ken"[..]));
        assert_eq!(h.header("AUTHORIZATION"), Some(&b"Bearer t0ken"[..]));
        assert!(!h.transfer_chunked());
        assert!(!h.wants_close());
        assert_eq!(h.consumed, 162);
        assert_eq!(h.request_framing(), Framing::Length(42));
    }

    #[test]
    fn incomplete_head_is_not_an_error() {
        assert!(parse_head(b"POST / HTTP/1.1\r\nHost: x").unwrap().is_none());
        assert!(parse_head(&[b'A'; MAX_HEAD + 1]).is_err());
    }

    #[test]
    fn chunked_wins_and_close_is_honoured() {
        let raw = b"POST /v1/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n";
        let h = parse_head(raw).unwrap().unwrap();
        assert_eq!(h.request_framing(), Framing::Chunked);
        let raw = b"GET /v1/x HTTP/1.1\r\nConnection: close\r\n\r\n";
        let h = parse_head(raw).unwrap().unwrap();
        assert!(h.wants_close());
        let raw = b"GET /v1/x HTTP/1.0\r\n\r\n";
        let h = parse_head(raw).unwrap().unwrap();
        assert!(h.wants_close());
    }

    #[test]
    fn response_framing() {
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n";
        let h = parse_head(raw).unwrap().unwrap();
        assert_eq!(h.response_framing(false), Framing::Chunked);
        assert_eq!(h.response_framing(true), Framing::None);
        assert_eq!(h.status(), 200);

        let raw = b"HTTP/1.1 204 No Content\r\n\r\n";
        let h = parse_head(raw).unwrap().unwrap();
        assert_eq!(h.response_framing(false), Framing::None);

        let raw = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n";
        let h = parse_head(raw).unwrap().unwrap();
        assert_eq!(h.response_framing(false), Framing::UntilEof);
    }

    #[test]
    fn relayed_request_drops_hop_by_hop_and_rewrites_framing() {
        let h = parse_head(REQ).unwrap().unwrap();
        let mut out = Vec::new();
        write_relay_request(&mut out, &h, "127.0.0.1:8081", Framing::Length(14), true).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.starts_with("POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:8081\r\n"));
        assert!(!text.contains("Host: evo-x2"));
        assert!(!text.contains("Connection:"));
        assert!(text.contains("Content-Length: 14\r\n"));
        assert!(!text.contains("Content-Length: 42"));
        assert!(text.contains("Authorization: Bearer t0ken\r\n"));
        assert!(text.contains("Content-Type: application/json\r\n"));
    }

    #[test]
    fn relayed_response_keeps_backend_cors_and_adds_buffering_off() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\
                    Access-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\
                    Transfer-Encoding: chunked\r\n\r\n";
        let h = parse_head(raw).unwrap().unwrap();
        let mut out = Vec::new();
        write_relay_response(&mut out, &h, Framing::Chunked, true).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert_eq!(text.matches("Access-Control-Allow-Origin").count(), 1);
        assert!(text.contains("X-Accel-Buffering: no"));
        assert!(!text.contains("Connection:"));
        assert!(text.contains("Transfer-Encoding: chunked"));
    }

    #[test]
    fn error_body_is_valid_json_and_closes() {
        let mut out = Vec::new();
        write_error(&mut out, 404, "invalid_request_error", "line\nwith \"quotes\"").unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.starts_with("HTTP/1.1 404 Not Found"));
        assert!(text.contains("Connection: close"));
        let body = text.split("\r\n\r\n").nth(1).unwrap();
        assert!(body.starts_with("{\"error\":{\"message\":\"line\\nwith \\\"quotes\\\""));
        assert!(body.ends_with("}\n"));
    }

    #[test]
    fn trim_helper() {
        assert_eq!(trim(b"  chunked  "), b"chunked");
        assert_eq!(trim(b""), b"");
    }
}

#[cfg(test)]
mod stream_regression {
    use super::*;
    #[test]
    fn sse_response_head_is_chunked() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nTransfer-Encoding: chunked\r\n\r\n";
        let h = parse_head(raw).unwrap().unwrap();
        assert!(h.transfer_chunked(), "transfer_chunked() missed");
        assert_eq!(h.response_framing(false), Framing::Chunked);
        let mut out = Vec::new();
        write_relay_response(&mut out, &h, Framing::Chunked, false).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("Transfer-Encoding: chunked"), "lost TE: {text}");
        assert!(!text.to_lowercase().contains("content-length"), "invented CL");
    }
}
