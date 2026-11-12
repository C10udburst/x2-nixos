//! Keep-alive pool for backend connections.
//!
//! A workload that is already resident is also already listening, so the *only* thing a warm
//! request needs is a socket to it. Without a pool that is a `socket`+`connect`+`close` per
//! request; with it a repeated chat session costs nothing at all on the connection axis.
//!
//! Design notes:
//!
//! * **Lazy expiry.** Entries carry the moment they were returned and are dropped when they
//!   are taken too late - there is no reaper thread, so an idle router never wakes up.
//! * **Optimistic reuse.** A pooled socket whose peer died is discovered on first write; the
//!   caller then reconnects and retries (only before any byte of the reply has reached the
//!   client), so a stopped workload costs one extra connect, not a failed request.
//! * **Nothing pooled after an unload.** A workload switch clears the pool, so a socket can
//!   never outlive the process that owns the accelerator.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::registry::Entry;
use crate::stream::Stream;

struct Idle {
    stream: Stream,
    since: Instant,
}

pub struct Pool {
    idle: Mutex<HashMap<(String, u16), Vec<Idle>>>,
    max_per_backend: usize,
    idle_ttl: Duration,
}

impl Pool {
    pub fn new(max_per_backend: usize, idle_ttl: Duration) -> Pool {
        Pool {
            idle: Mutex::new(HashMap::new()),
            max_per_backend,
            idle_ttl,
        }
    }

    /// Take a warm socket to `entry`, or `None`. Expired entries are dropped on the way out.
    pub fn take(&self, entry: &Entry) -> Option<Stream> {
        let key = (entry.host.clone(), entry.port);
        let mut guard = self.idle.lock().ok()?;
        let bucket = guard.get_mut(&key)?;
        while let Some(candidate) = bucket.pop() {
            if candidate.since.elapsed() <= self.idle_ttl {
                return Some(candidate.stream);
            }
        }
        None
    }

    /// Return a socket that finished an exchange cleanly.
    pub fn put(&self, entry: &Entry, stream: Stream) {
        let Ok(mut guard) = self.idle.lock() else {
            return;
        };
        let bucket = guard
            .entry((entry.host.clone(), entry.port))
            .or_insert_with(Vec::new);
        if bucket.len() >= self.max_per_backend {
            return; // dropping the stream closes it
        }
        bucket.push(Idle {
            stream,
            since: Instant::now(),
        });
    }

    /// Drop any idle socket to one backend. Used when an exchange ended with `Connection:
    /// close`: the peer is going away, so a pooled fd for it would only fail on next use.
    pub fn evict(&self, entry: &Entry) {
        if let Ok(mut guard) = self.idle.lock() {
            guard.remove(&(entry.host.clone(), entry.port));
        }
    }



    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.idle
            .lock()
            .map(|guard| guard.values().map(Vec::len).sum())
            .unwrap_or(0)
    }
}
