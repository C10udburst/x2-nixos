//! Finding the requested model id without parsing the request.
//!
//! The router must know *which* workload a request belongs to before it may touch it, and the
//! model may be spelled in four places. Each is answered by a byte scan that stops at the
//! first complete answer, so nothing after the model id is ever read, decoded, or copied:
//!
//! | source | how |
//! | --- | --- |
//! | `?model=...` | split the request target at `?`, take the param, percent-decode |
//! | `X-Model: ...` | header value, no body read at all |
//! | JSON body | depth-aware scan for a **top-level** `"model"` string |
//! | `multipart/form-data` | the `form-data` part whose `name="model"` |
//! | `x-www-form-urlencoded` | the `model=` field |
//!
//! The JSON case is why there is no JSON crate in this project: a ~100 line scanner that
//! tracks strings, escapes and container depth answers "what is the top-level `model`" faster
//! than any real parser, and - critically - it cannot be fooled by a `"model"` key buried in
//! a message, a tool result, or a nested object, because those sit at depth > 1.
//!
//! Every scanner returns [`Hit`] so the caller can distinguish "not here" from "I need more
//! bytes": the caller peeks a few KiB, rescans on demand, and only keeps reading while a
//! decision is genuinely still open.

use std::ops::Range;

/// Where a scan stands after looking at the bytes it was given.
#[derive(Debug, PartialEq, Eq)]
pub enum Hit {
    /// The model id lives in `buf[range]` (raw bytes, still percent-encoded for query/form).
    Found(Range<usize>),
    /// A decision needs bytes this window does not have yet.
    NeedMore,
    /// This body definitively does not name a model.
    Absent,
}

impl Hit {
    pub fn range(&self) -> Option<Range<usize>> {
        match self {
            Hit::Found(r) => Some(r.clone()),
            _ => None,
        }
    }
}

/// Which shape the body had, so the caller knows whether to percent-decode.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Source {
    Json,
    Multipart,
    Form,
}

/// Scan a request body for the model id.
///
/// `final_` tells the scanner that no further bytes will ever arrive: an unterminated value
/// is then answered with what it has instead of [`Hit::NeedMore`].
pub fn body(content_type: Option<&[u8]>, buf: &[u8], final_: bool) -> Option<(Source, Hit)> {
    match classify(content_type) {
        Source::Json => Some((Source::Json, json(buf, final_))),
        Source::Multipart => Some((Source::Multipart, multipart(buf, final_))),
        Source::Form => Some((Source::Form, form(buf, final_))),
    }
}

/// Anything that is not explicitly a form is treated as JSON: every OpenAI-compatible client
/// sends `application/json`, and a wrong guess can only ever end in [`Hit::Absent`].
fn classify(content_type: Option<&[u8]>) -> Source {
    let ct = match content_type {
        Some(ct) => lower_ascii(ct),
        None => return Source::Json,
    };
    let ct: &[u8] = &ct;
    if starts_with_trimmed(ct, b"multipart/") {
        Source::Multipart
    } else if contains(ct, b"x-www-form-urlencoded") {
        Source::Form
    } else {
        Source::Json
    }
}

fn starts_with_trimmed(hay: &[u8], needle: &[u8]) -> bool {
    let start = hay.iter().position(|&b| !is_ws(b)).unwrap_or(hay.len());
    hay[start..].starts_with(needle)
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    find(hay, needle).is_some()
}

// --------------------------------------------------------------------------- JSON

/// Top-level `"model"` of a JSON object. Strings and container depth are tracked precisely,
/// so nested `"model"` keys (tool calls, message content, provider extensions) are ignored.
pub fn json(buf: &[u8], final_: bool) -> Hit {
    let mut i = skip_ws(buf, 0);
    if i >= buf.len() {
        return if final_ { Hit::Absent } else { Hit::NeedMore };
    }
    if buf[i] != b'{' {
        return Hit::Absent;
    }

    /// Nesting is bounded: an OpenAI request body never comes close to this, and if something
    /// absurd does, we say "no model here" rather than allocate a stack.
    const MAX_DEPTH: usize = 128;
    let mut object_stack = [false; MAX_DEPTH];
    let mut depth = 0usize;
    // True when the next string token is a member name (as opposed to a value).
    let mut key_slot = false;

    loop {
        if i >= buf.len() {
            return if final_ { Hit::Absent } else { Hit::NeedMore };
        }
        match buf[i] {
            b' ' | b'\t' | b'\n' | b'\r' => i += 1,
            b'{' => {
                if depth >= MAX_DEPTH {
                    return Hit::Absent;
                }
                object_stack[depth] = true;
                depth += 1;
                i += 1;
                key_slot = true;
            }
            b'[' => {
                if depth >= MAX_DEPTH {
                    return Hit::Absent;
                }
                object_stack[depth] = false;
                depth += 1;
                i += 1;
                key_slot = false;
            }
            b'}' | b']' => {
                depth = depth.saturating_sub(1);
                i += 1;
                key_slot = false;
                if depth == 0 {
                    // The top-level object closed without naming a model.
                    return Hit::Absent;
                }
            }
            b',' => {
                i += 1;
                key_slot = depth >= 1 && object_stack[depth - 1];
            }
            b':' => i += 1,
            b'"' => match string_token(buf, i) {
                None => return if final_ { Hit::Absent } else { Hit::NeedMore },
                Some((content, next)) => {
                    if depth == 1 && key_slot && &buf[content.clone()] == b"model" {
                        let j = skip_ws(buf, next);
                        if j >= buf.len() {
                            return if final_ { Hit::Absent } else { Hit::NeedMore };
                        }
                        if buf[j] != b':' {
                            // Not a member after all (e.g. `["model", ...]`); keep walking.
                            key_slot = false;
                            i = j;
                            continue;
                        }
                        let k = skip_ws(buf, j + 1);
                        if k >= buf.len() {
                            return if final_ { Hit::Absent } else { Hit::NeedMore };
                        }
                        if buf[k] != b'"' {
                            // "model": 42 / null / {} - nothing we can route on.
                            return Hit::Absent;
                        }
                        return match string_token(buf, k) {
                            Some((value, _)) => Hit::Found(value),
                            None => {
                                if final_ {
                                    Hit::Absent
                                } else {
                                    Hit::NeedMore
                                }
                            }
                        };
                    }
                    key_slot = false;
                    i = next;
                }
            },
            // numbers, true/false/null, and any stray byte: not a key, walk on.
            _ => i += 1,
        }
    }
}

/// `buf[i]` is the opening quote. Returns the content span (quotes excluded) and the index
/// just past the closing quote, or `None` when the string is not terminated inside `buf`.
fn string_token(buf: &[u8], i: usize) -> Option<(Range<usize>, usize)> {
    let start = i + 1;
    let mut j = start;
    while j < buf.len() {
        match buf[j] {
            b'\\' => j += 2,
            b'"' => return Some((start..j, j + 1)),
            _ => j += 1,
        }
    }
    None
}

// -------------------------------------------------------------------- multipart

/// The `model` field of a `multipart/form-data` body.
///
/// A part is only accepted when its `Content-Disposition` line says `form-data` **and**
/// carries `name="model"` - requiring both is what keeps a `name="model"` sequence inside an
/// uploaded file's bytes from being mistaken for the field.
pub fn multipart(buf: &[u8], final_: bool) -> Hit {
    let mut from = 0usize;
    while let Some(at) = find_ci(&buf[from..], b"name=") {
        let at = from + at;
        let token_end = match field_token(buf, at + 5) {
            Some((name_end, is_model)) => {
                if !is_model {
                    from = name_end;
                    continue;
                }
                name_end
            }
            None => return if final_ { Hit::Absent } else { Hit::NeedMore },
        };
        // The header line this `name=` lives on must also mention form-data.
        let line = line_bounds(buf, at);
        match line {
            None => return if final_ { Hit::Absent } else { Hit::NeedMore },
            Some((ls, le)) => {
                if !contains_ci(&buf[ls..le], b"form-data") {
                    from = token_end;
                    continue;
                }
                // Everything up to the blank line is part headers; the value follows it.
                let sep = match find_eoh(&buf[le..]) {
                    None => return if final_ { Hit::Absent } else { Hit::NeedMore },
                    Some((value_start, _)) => le + value_start,
                };
                let value_end = match find_line_end(&buf[sep..]) {
                    None => {
                        if final_ {
                            buf.len()
                        } else {
                            return Hit::NeedMore;
                        }
                    }
                    Some(end) => sep + end,
                };
                return if value_end > sep {
                    Hit::Found(sep..value_end)
                } else {
                    // An empty model field is not a routing decision.
                    Hit::Absent
                };
            }
        }
    }
    Hit::Absent
}

/// Parse an unquoted or quoted parameter value starting at `buf[i]`.
/// Returns `(end, value == "model")`.
fn field_token(buf: &[u8], i: usize) -> Option<(usize, bool)> {
    if i >= buf.len() {
        return None;
    }
    if buf[i] == b'"' {
        let close = find(&buf[i + 1..], b"\"")?;
        let value = &buf[i + 1..i + 1 + close];
        Some((i + 2 + close, value == b"model"))
    } else {
        let mut j = i;
        while j < buf.len() && buf[j] != b';' && buf[j] != b'"' && !is_ws(buf[j]) {
            j += 1;
        }
        if j >= buf.len() {
            return None;
        }
        Some((j, &buf[i..j] == b"model"))
    }
}

fn line_bounds(buf: &[u8], i: usize) -> Option<(usize, usize)> {
    let start = buf[..i].iter().rposition(|&b| b == b'\n').map(|p| p + 1)?;
    let end = buf[i..].iter().position(|&b| b == b'\r' || b == b'\n').map(|p| i + p)?;
    Some((start, end))
}

/// Position of the empty line that ends a part's headers: `(value_start, after)`.
fn find_eoh(buf: &[u8]) -> Option<(usize, usize)> {
    if let Some(p) = find(buf, b"\r\n\r\n") {
        return Some((p + 4, p + 4));
    }
    if let Some(p) = find(buf, b"\n\n") {
        return Some((p + 2, p + 2));
    }
    None
}

fn find_line_end(buf: &[u8]) -> Option<usize> {
    buf.iter().position(|&b| b == b'\r' || b == b'\n')
}

// ----------------------------------------------------------------------- forms

/// The `model=` field of a urlencoded body (and of a request target's query string).
pub fn form(buf: &[u8], final_: bool) -> Hit {
    let mut from = 0usize;
    while let Some(at) = find(&buf[from..], b"model=") {
        let at = from + at;
        let is_field = at == 0 || buf[at - 1] == b'&' || buf[at - 1] == b'?';
        if !is_field {
            from = at + 6;
            continue;
        }
        let start = at + 6;
        let end = match buf[start..].iter().position(|&b| b == b'&' || b == b'\r' || b == b'\n') {
            Some(p) => start + p,
            None if final_ => buf.len(),
            None => return Hit::NeedMore,
        };
        return if end > start {
            Hit::Found(start..end)
        } else {
            Hit::Absent
        };
    }
    Hit::Absent
}

/// `model=` inside a request target, percent-decoded into `out` unless nothing needs decoding.
///
/// A URI query is **not** form encoding: `+` stays a literal plus here (RFC 3986), so an id like
/// `gpt+4` survives intact. Only `application/x-www-form-urlencoded` *bodies* use `+` for space.
pub fn query<'a>(target: &'a [u8], out: &'a mut Vec<u8>) -> Option<&'a [u8]> {
    let qmark = target.iter().position(|&b| b == b'?')?;
    let raw = form(&target[qmark..], true).range()?;
    // Offsets are relative to the query string; `?` is 1 byte, and the raw value begins
    // `qmark + raw.start` bytes into the target.
    let absolute = qmark + raw.start;
    let bytes = &target[absolute..qmark + raw.end];
    if bytes.iter().any(|&b| b == b'%' || b == b'+') {
        percent_decode(bytes, false, out);
        Some(out)
    } else {
        Some(bytes)
    }
}

/// Percent-decode into `out`.
///
/// `plus_as_space` distinguishes the two encodings that look identical:
/// * `false` - a URI path or query value (RFC 3986): `+` is a literal plus, only `%XX` decodes.
///   This is what nginx forwards in `?model=...` and what a JSON string body carries.
/// * `true` - an `application/x-www-form-urlencoded` pair, where `+` means space.
///
/// Getting this wrong silently renames a model: an id containing `+` would be looked up with a
/// space and fail with "not in the registry".
pub fn percent_decode(src: &[u8], plus_as_space: bool, out: &mut Vec<u8>) {
    out.clear();
    let mut i = 0;
    while i < src.len() {
        // `i + 2 < len` would reject a escape occupying the final three bytes.
        if src[i] == b'%' && i + 3 <= src.len() {
            if let (Some(hi), Some(lo)) = (hex(src[i + 1]), hex(src[i + 2])) {
                out.push(hi * 16 + lo);
                i += 3;
                continue;
            }
        }
        if src[i] == b'+' && plus_as_space {
            out.push(b' ');
        } else {
            out.push(src[i]);
        }
        i += 1;
    }
}

fn hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

// ------------------------------------------------------------------ byte helpers

fn is_ws(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | b'\r')
}

fn skip_ws(buf: &[u8], mut i: usize) -> usize {
    while i < buf.len() && is_ws(buf[i]) {
        i += 1;
    }
    i
}

/// Substring search on the first byte, then memcmp - fine for windows of a few KiB.
pub fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    let first = needle[0];
    let last = hay.len() - needle.len();
    let mut i = 0;
    while i <= last {
        if hay[i] != first {
            i += 1;
            continue;
        }
        if &hay[i..i + needle.len()] == needle {
            return Some(i);
        }
        i += 1;
    }
    None
}

fn find_ci(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    let last = hay.len() - needle.len();
    'outer: for i in 0..=last {
        for (o, &n) in needle.iter().enumerate() {
            if hay[i + o].to_ascii_lowercase() != n {
                continue 'outer;
            }
        }
        return Some(i);
    }
    None
}

fn contains_ci(hay: &[u8], needle: &[u8]) -> bool {
    find_ci(hay, needle).is_some()
}

fn lower_ascii(bytes: &[u8]) -> Vec<u8> {
    bytes.iter().map(|b| b.to_ascii_lowercase()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn found(buf: &[u8]) -> Option<String> {
        match json(buf, true) {
            Hit::Found(r) => Some(String::from_utf8_lossy(&buf[r]).to_string()),
            _ => None,
        }
    }

    #[test]
    fn json_finds_top_level_model() {
        let b = br#"{"model":"gpt-4","messages":[]}"#;
        assert_eq!(found(b), Some("gpt-4".into()));
        // model last, whitespace, newlines
        let b = b"{\n  \"messages\": [{\"role\":\"user\",\"content\":\"hi\"}],\n  \"model\" : \"deepseek-v4-flash\" ,\n  \"stream\": true\n}";
        assert_eq!(found(b), Some("deepseek-v4-flash".into()));
    }

    #[test]
    fn json_ignores_nested_model_keys() {
        // The classic false positive: a tool result carrying someone else's JSON payload.
        let b = br#"{"messages":[{"role":"tool","content":"{\"model\":\"victim\",\"x\":1}"}],"model":"real-model"}"#;
        assert_eq!(found(b), Some("real-model".into()));

        // Nested object member named model at depth 2 must never win.
        let b = br#"{"extra":{"model":"decoy"},"model":"real"}"#;
        assert_eq!(found(b), Some("real".into()));

        // An array of objects that each have "model".
        let b = br#"{"items":[{"model":"a"},{"model":"b"}]}"#;
        assert_eq!(found(b), None);
    }

    #[test]
    fn json_handles_escapes_and_unicode() {
        let b = br#"{"a":"say \"model\":\"x\" loudly","model":"ok"}"#;
        assert_eq!(found(b), Some("ok".into()));
        let b = br#"{"model":"\u00fcber-model","stream":false}"#;
        assert_eq!(found(b), Some("\\u00fcber-model".into()));
    }

    #[test]
    fn json_reports_need_more_until_the_value_is_complete() {
        assert_eq!(json(br#"{"model":"par"#, false), Hit::NeedMore);
        assert_eq!(json(br#"{"model":"part"#, true), Hit::Absent); // final and truncated
        assert_eq!(json(b"{", false), Hit::NeedMore);
        assert_eq!(json(br#"{"other":1}"#, false), Hit::Absent);
        assert_eq!(json(br#"not json at all"#, false), Hit::Absent);
        assert_eq!(json(br#"{"model": 123}"#, false), Hit::Absent);
    }

    #[test]
    fn multipart_finds_the_model_field() {
        let mut body = Vec::new();
        body.extend_from_slice(b"--BND\r\n");
        body.extend_from_slice(b"Content-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\n");
        body.extend_from_slice(b"Content-Type: image/png\r\n\r\n");
        body.extend_from_slice(&[0x89u8, b'P', b'N', b'G']);
        body.extend_from_slice(b" binary-ish name=\"model\" inside\r\n");
        body.extend_from_slice(b"--BND\r\n");
        body.extend_from_slice(b"Content-Disposition: form-data; name=\"model\"\r\n\r\n");
        body.extend_from_slice(b"glm-ocr\r\n");
        body.extend_from_slice(b"--BND--\r\n");
        match multipart(&body, false) {
            Hit::Found(r) => assert_eq!(&body[r], b"glm-ocr"),
            other => panic!("expected found, got {other:?}"),
        }
    }

    #[test]
    fn multipart_accepts_unquoted_names_and_skips_decoys() {
        let body = concat!(
            "--B\r\n",
            "Content-Disposition: form-data; name=model\r\n\r\n",
            "ripple-65b\r\n",
            "--B--\r\n",
        )
        .as_bytes();
        match multipart(body, false) {
            Hit::Found(r) => assert_eq!(&body[r], b"ripple-65b"),
            other => panic!("expected found, got {other:?}"),
        }

        // name="model" without form-data on the same line is not a field.
        let body = b"blob name=\"model\"\r\nvalue\r\n";
        assert_eq!(multipart(body, true), Hit::Absent);
        // name="model_x" must not match.
        let body = concat!("--B\r\nContent-Disposition: form-data; name=\"model_name\"\r\n\r\nx\r\n--B--\r\n").as_bytes();
        assert_eq!(multipart(body, true), Hit::Absent);
    }

    #[test]
    fn form_and_query() {
        let b = b"other=1&model=humanizer&x=2";
        match form(b, false) {
            Hit::Found(r) => assert_eq!(&b[r], b"humanizer"),
            other => panic!("got {other:?}"),
        }
        let mut out = Vec::new();
        let t = b"/v1/chat/completions?model=llama%203&x=1";
        assert_eq!(query(t, &mut out), Some(&b"llama 3"[..]));
        let t = b"/v1/embeddings?model=bge-m3";
        assert_eq!(query(t, &mut out), Some(&b"bge-m3"[..]));
        assert_eq!(query(b"/v1/chat", &mut out), None);
    }

    #[test]
    fn classification_and_dispatch() {
        let (src, hit) = body(Some(b"application/json; charset=utf-8"), br#"{"model":"x"}"#, false).unwrap();
        assert_eq!(src, Source::Json);
        assert_eq!(hit.range().unwrap(), 10..11);
        let (src, _) = body(Some(b"multipart/form-data; boundary=B"), b"", false).unwrap();
        assert_eq!(src, Source::Multipart);
        let (src, _) = body(Some(b"application/x-www-form-urlencoded"), b"", false).unwrap();
        assert_eq!(src, Source::Form);
        let (src, _) = body(None, b"", false).unwrap();
        assert_eq!(src, Source::Json);
    }

    #[test]
    fn percent_decode_handles_edges() {
        let mut out = Vec::new();
        // URI form: '+' is a literal plus, only %XX decodes.
        percent_decode(b"a%20b%2Fc+d%zz", false, &mut out);
        assert_eq!(out, b"a b/c+d%zz"); // %zz is not valid hex, passed through
        // Form form: '+' additionally means space.
        percent_decode(b"a%20b%2Fc+d%zz", true, &mut out);
        assert_eq!(out, b"a b/c d%zz");
        // An escape occupying exactly the last three bytes must still decode - an off-by-one
        // here silently corrupts the model id.
        percent_decode(b"ab%2F", false, &mut out);
        assert_eq!(out, b"ab/");
        // A truncated escape stays verbatim rather than eating bytes.
        percent_decode(b"ab%2", false, &mut out);
        assert_eq!(out, b"ab%2");
        percent_decode(b"", false, &mut out);
        assert_eq!(out, b"");
    }

    #[test]
    fn query_keeps_plus_literal_but_form_bodies_do_not() {
        let mut out = Vec::new();
        // RFC 3986: a model id containing '+' must arrive intact through ?model=.
        assert_eq!(query(b"/v1/chat?model=a+b", &mut out), Some(&b"a+b"[..]));
        assert_eq!(query(b"/v1/chat?model=a%2Bb", &mut out), Some(&b"a+b"[..]));
        assert_eq!(query(b"/v1/chat?model=a%20b", &mut out), Some(&b"a b"[..]));
        assert_eq!(query(b"/v1/chat", &mut out), None);
        // The same bytes in a form body mean a space.
        let (_src, hit) = body(Some(b"application/x-www-form-urlencoded"), b"model=a+b", true).unwrap();
        let raw = &b"model=a+b"[hit.range().unwrap()];
        assert_eq!(raw, b"a+b");
        percent_decode(raw, true, &mut out);
        assert_eq!(out, b"a b");
    }
}
