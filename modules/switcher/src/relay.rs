//! Chunk framing tracker for `Transfer-Encoding: chunked` messages.
//!
//! The relay forwards chunked bodies **verbatim**; this module only answers two questions about
//! a byte stream, and never re-frames anything:
//!
//! * how many payload bytes are in these wire bytes (so a model id can be read out of a chunked
//!   request body), and
//! * is the message complete (so a connection may be reused).
//!
//! Getting the second one wrong would either truncate an SSE token stream or hand a still-busy
//! backend socket to another request.

// ------------------------------------------------------------------ "still loading"

/// Substrings that mean "a process answers, but its weights are not resident yet".
///
/// llama-server binds its listening socket before loading the model and keeps replying
/// `503 {"error":{"message":"Loading model",...}}` for as long as that takes - minutes on a
/// multi-hundred-gigabyte GGUF. Both the readiness probe (`workload::probe`) and the relay use
/// this so the two can never disagree about what "not ready" looks like.
const LOADING_MARKERS: &[&[u8]] = &[
    b"loading model",
    b"model is loading",
    b"loading_model",
    b"server is loading",
];

/// Does this response say the backend is still loading?
///
/// `head` is the raw response head and `prefix` any body bytes already read with it. Matching the
/// *body* rather than the status code is deliberate: a 503 alone could be overload, and a `< 500`
/// carrying this message must still count as not-ready.
pub fn says_loading(head: &[u8], prefix: &[u8]) -> bool {
    let mut haystack = Vec::with_capacity(head.len() + prefix.len());
    haystack.extend_from_slice(head);
    haystack.extend_from_slice(prefix);
    haystack.make_ascii_lowercase();
    LOADING_MARKERS
        .iter()
        .any(|marker| haystack.windows(marker.len()).any(|w| w == *marker))
}



// ------------------------------------------------------------------------ chunked

#[derive(PartialEq, Clone, Copy)]
enum DState {
    Size,
    Extension,
    SizeCr,
    Payload,
    PayloadCr,
    PayloadLf,
    Trailer,
    TrailerLine,
    TrailerCr,
    Done,
}

/// Tracks `Transfer-Encoding: chunked` framing.
///
/// The framing itself is relayed untouched (see [`crate::handler`]); this machine only answers
/// two questions: *how many payload bytes are in these wire bytes* (so a model id can be read
/// out of a chunked body) and *is the message complete* (so a connection may be reused).
#[derive(Clone)]
pub struct Chunked {
    state: DState,
    hex: u64,
    remain: u64,
    done: bool,
}

impl Default for Chunked {
    fn default() -> Self {
        Chunked {
            state: DState::Size,
            hex: 0,
            remain: 0,
            done: false,
        }
    }
}

impl Chunked {
    pub fn new() -> Chunked {
        Chunked::default()
    }

    pub fn done(&self) -> bool {
        self.done
    }

    /// Consume wire bytes, appending only payload bytes to `out`. Returns `true` once the
    /// zero-length chunk and its trailing headers have been seen.
    pub fn feed(&mut self, raw: &[u8], mut out: Option<&mut Vec<u8>>) -> bool {
        let mut i = 0usize;
        while i < raw.len() && !self.done {
            match self.state {
                DState::Size => {
                    let b = raw[i];
                    i += 1;
                    if b == b';' {
                        self.state = DState::Extension;
                    } else if b == b'\r' {
                        self.state = DState::SizeCr;
                    } else if b == b'\n' {
                        self.open_chunk();
                    } else if let Some(d) = hex_digit(b) {
                        self.hex = self.hex.saturating_mul(16).saturating_add(d);
                    }
                }
                DState::Extension => {
                    let b = raw[i];
                    i += 1;
                    if b == b'\r' {
                        self.state = DState::SizeCr;
                    } else if b == b'\n' {
                        self.open_chunk();
                    }
                }
                DState::SizeCr => {
                    let b = raw[i];
                    i += 1;
                    if b == b'\n' {
                        self.open_chunk();
                    } else if let Some(d) = hex_digit(b) {
                        // A stray byte after CR: keep parsing the size line.
                        self.state = DState::Size;
                        self.hex = self.hex.saturating_mul(16).saturating_add(d);
                    }
                }
                DState::Payload => {
                    let take = (self.remain as usize).min(raw.len() - i);
                    if let Some(out) = out.as_mut() {
                        out.extend_from_slice(&raw[i..i + take]);
                    }
                    self.remain -= take as u64;
                    i += take;
                    if self.remain == 0 {
                        self.state = DState::PayloadCr;
                    }
                }
                DState::PayloadCr => {
                    // After the last payload byte comes CRLF (or a bare LF). Consume CR here,
                    // then LF in PayloadLf, and only then return to parsing sizes.
                    let b = raw[i];
                    i += 1;
                    if b == b'\n' {
                        // Bare LF terminator (non-standard but seen in the wild).
                        self.state = DState::Size;
                    } else {
                        // Normal CR; the LF follows in PayloadLf.
                        self.state = DState::PayloadLf;
                    }
                }
                DState::PayloadLf => {
                    // Consume the LF that closes the chunk's CRLF terminator.
                    i += 1;
                    self.state = DState::Size;
                }
                DState::Trailer => {
                    let b = raw[i];
                    i += 1;
                    match b {
                        b'\n' => {
                            self.done = true;
                            self.state = DState::Done;
                        }
                        b'\r' => self.state = DState::TrailerCr,
                        _ => self.state = DState::TrailerLine,
                    }
                }
                DState::TrailerLine => {
                    let b = raw[i];
                    i += 1;
                    if b == b'\n' {
                        self.state = DState::Trailer;
                    }
                }
                DState::TrailerCr => {
                    let b = raw[i];
                    i += 1;
                    self.state = if b == b'\n' {
                        self.done = true;
                        DState::Done
                    } else {
                        DState::TrailerLine
                    };
                }
                DState::Done => break,
            }
        }
        self.done
    }

    fn open_chunk(&mut self) {
        if self.hex == 0 {
            // After the last chunk come optional trailers and one empty line.
            self.state = DState::Trailer;
        } else {
            self.remain = self.hex;
            self.state = DState::Payload;
        }
        self.hex = 0;
    }
}

fn hex_digit(b: u8) -> Option<u64> {
    match b {
        b'0'..=b'9' => Some((b - b'0') as u64),
        b'a'..=b'f' => Some((b - b'a' + 10) as u64),
        b'A'..=b'F' => Some((b - b'A' + 10) as u64),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunked_tracks_payload_and_end() {
        // 0x13 = 19 = len("world and then some")
        let wire = b"5\r\nhello\r\n13\r\nworld and then some\r\n0\r\n\r\n";
        let mut payload = Vec::new();
        let mut c = Chunked::new();
        let mut fed = 0;
        // Feed one byte at a time: the machine must be split-proof.
        while fed < wire.len() && !c.done() {
            let end = (fed + 1).min(wire.len());
            c.feed(&wire[fed..end], Some(&mut payload));
            fed = end;
        }
        assert!(c.done());
        // Chunked framing concatenates payload bytes with no separator between chunks.
        assert_eq!(payload, b"helloworld and then some");
    }

    #[test]
    fn chunked_handles_extensions_and_trailers() {
        let wire = b"5;ext=1\r\nhello\r\n0\r\nX-Trail: yes\r\n\r\n";
        let mut payload = Vec::new();
        let mut c = Chunked::new();
        c.feed(wire, Some(&mut payload));
        assert!(c.done());
        assert_eq!(payload, b"hello");
    }

    #[test]
    fn chunked_sse_stream_is_never_marked_done_early() {
        let mut c = Chunked::new();
        let mut payload = Vec::new();
        // Two SSE chunks streamed back-to-back; neither may mark the message done.
        let sse_line = |n: u8| -> Vec<u8> {
            format!("data: {{\"choices\":[{{\"delta\":{{\"content\":\"tok{n}\"}}}}]}}\n\n").into_bytes()
        };
        for line in [sse_line(1), sse_line(2)] {
            let wire = format!("{:x}\r\n", line.len()).into_bytes();
            c.feed(&wire, None);
            c.feed(&line, Some(&mut payload));
            c.feed(b"\r\n", None);
            assert!(!c.done());
        }
        assert_eq!(payload, [sse_line(1), sse_line(2)].concat());
    }


}
