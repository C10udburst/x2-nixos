# `/v1/*` router daemon

One resident Rust process that replaces the FastCGI `switcher.sh` CGI on the inference hot path.
nginx `proxy_pass`es `/v1/*` (and `/completion`) to its Unix socket; the router decides which
model must be resident, starts it if it is not, and relays the response.

```
client -> nginx :8080  --unix-->  switcher  --http/1.1-->  127.0.0.1:<backend port>
                                     |
                                     +-> flock /run/model-lock/<device>.lock
                                     +-> stop-other-workloads <device> <unit>
                                     +-> systemctl start <unit>
                                     +-> GET /health (poll)
```

## Why a daemon instead of a CGI

The Bash version forked `bash` + `jq` + `curl` per request and needed eight preforked
`fastcgiwrap` workers to hold concurrent streams. Concretely:

| | `switcher.sh` (FastCGI) | this daemon |
| --- | --- | --- |
| processes per request | 3-5 forks (`bash`, `jq`, `curl`, `flock`, `systemctl`) | 0 |
| model id extraction | `jq` over the whole body | single-pass byte scan, stops at the top-level `model` |
| concurrency ceiling | number of preforked workers | one thread per connection, capped by `--worker-max` |
| backend connections | new TCP connection every request | keep-alive pool per backend |
| idle cost | N live worker processes | blocked in `accept()`, measured **0.00 %** of a core |

## Dependency policy: zero Cargo dependencies

`Cargo.toml` has an empty `[dependencies]`. `flock(2)` - the one libc call `std` does not expose -
is a hand-written `extern "C"` declaration in `src/ffi.rs`. This is deliberate:

* `cargoHash` pins an **empty vendor tree**, so `nix flake update` never invalidates a dependency
  set and the build never needs the network.
* No HTTP framework means no buffering layer that could silently break SSE token streaming.
* The resulting binary links only `libc` and `libgcc_s` (~900 KB).

Body movement deliberately does **not** use `splice(2)`. A request cannot be forwarded before its
model id is known, and the id lives *inside* the body, so the payload has to land in userspace
anyway; a kernel zero-copy path would add a failure mode with no payoff.

## Wire format: `registry.nix` -> `src/registry.rs`

Tab-separated, one model per line, generated at Nix eval time from `services.models`:

```
devices \t id \t service \t remapped \t url \t model_dir \t engine \t capabilities
@default \t <id or empty>
```

`\`, TAB, CR and LF are escaped **in that order** by `registry.nix`, so a model id containing a
tab cannot forge a field boundary. `registry::wire_compat` asserts byte-for-byte agreement with
the Nix side: if either changes alone, the test fails instead of models silently vanishing.

`capabilities` may be empty, which means "the runner decides" - nothing is then refused on route
grounds.

## Behaviour worth knowing before editing

* **Resolution order**: `?model=` query → `X-Model` header → body's **top-level** `model` field
  (JSON / multipart / form-urlencoded) → registry `@default`. Nested `"model"` keys are ignored on
  purpose; a decoy inside `extra_body` must not reroute a request.
* **`+` is not a space in a URI.** `?model=a+b` means the literal id `a+b` (RFC 3986); only
  `application/x-www-form-urlencoded` bodies treat `+` as a space. Getting this wrong renames
  models. See `scan::percent_decode(src, plus_as_space, out)`.
* **Route matching order matters.** `/v1/chat/completions` also ends with `/completions`; matching
  the generic suffix first made every chat-only model fail its own chat endpoint. `chat` and
  `completions` are treated as one family in `Registry::serves_route`.
* **Locks are acquired in `Device::LOCK_ORDER`** (`gpu` then `npu`), deduplicated, exactly like
  §3 of `AGENTS.md`. A future model declaring `gpu,npu` therefore cannot deadlock against the wake
  scripts or the dashboard.
* **Chunked framing is forwarded verbatim**, never re-framed. `relay::Chunked` only tracks how many
  payload bytes a wire slice contains and whether the message is complete - getting the latter
  wrong would truncate an SSE stream or hand a still-busy backend socket to another request.
* **Bodies are bounded** by `--max-body` (default 512 MiB). The router must buffer a body to find
  the model id, so without this a large upload sizes the heap; over-limit is `413`.
* **Overload answers `503`.** The accept loop counts live workers and refuses *before* spawning,
  which is the only moment the fresh socket is still available to answer on.
* **Pool entries die with their backend.** When a workload is stopped its idle sockets are dropped,
  otherwise the next request would write into a closed connection.

## Development

```sh
cd modules/switcher
cargo test                        # unit tests (also run by the Nix build's checkPhase)
cargo build --release

# Run standalone against a fake registry. Orchestration is stubbed out so no real units move:
./target/release/switcher \
  --registry ./dev-registry.tsv \
  --listen tcp:127.0.0.1:8082 \
  --lock-dir /tmp/model-lock \
  --sudo '' --systemctl "$(command -v true)" \
  --stop-script "$(command -v true)" \
  --startup-timeout 5
```

`--sudo ''` runs `systemctl` directly as the current user; on the host the unit instead passes
`/run/wrappers/bin/sudo`, because `gateway` holds passwordless sudo for `systemctl` and
`stop-other-workloads` (see `modules/workload-manager.nix`).

Build through Nix (this is what ships, and it runs the tests):

```sh
nix build .#switcher
```

## Known limitations

* A request whose body is the *only* place the model appears must be buffered before routing, so
  peak RSS scales with the largest in-flight body up to `--max-body`. Streaming *responses* are
  unaffected - they are relayed chunk by chunk.
* One thread per connection rather than an event loop. At the intended scale (a single-user
  gateway behind nginx on a 16-core host) this avoids executor complexity entirely; raising
  `--worker-max` far beyond 512 would want a real scheduler instead.
* Health probing accepts any `< 500` response on `/health`, `/v1/models` or `/`, because the
  runners do not agree on a path. A backend that answers `404` before it can actually infer would
  be considered ready.
