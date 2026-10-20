#!/usr/bin/env python3
"""
FastCGI Reservation Management API for GMKtec EVO-X2.
Zero background daemons; state persisted in SQLite and evaluated strictly on-demand.

Modes:
- Semaphore: Indefinite exclusive lock (acquire/release).
- Time-boxed queue: Waitlist for specific durations with automatic expiration and early release.
- Recurring: Fixed daily schedule slots.
"""

import datetime
import hashlib
import json
import os
import sqlite3
import sys
import time
from urllib.parse import parse_qs

# Curated list of friendly, distinct adjectives and nouns for 2-word client names
ADJECTIVES = [
    "Amber", "Ancient", "Apex", "Astral", "Atomic", "Aurora", "Autumn", "Azure",
    "Blazing", "Bold", "Brave", "Bright", "Bronze", "Calm", "Cedar", "Celestial",
    "Cipher", "Clever", "Cobalt", "Copper", "Coral", "Cosmic", "Crimson", "Crystal",
    "Daring", "Dawn", "Diamond", "Echo", "Electric", "Emerald", "Epic", "Fierce",
    "Flaring", "Fleet", "Frosty", "Galactic", "Gentle", "Gilded", "Golden", "Grand",
    "Harmonic", "Heroic", "Hidden", "Hyper", "Indigo", "Infinite", "Iron", "Jade",
    "Kinetic", "Lunar", "Magic", "Mighty", "Mystic", "Nebula", "Noble", "Nova",
    "Onyx", "Optic", "Orion", "Patient", "Polar", "Prism", "Quantum", "Quick",
    "Radiant", "Rapid", "Ruby", "Rustic", "Sapphire", "Serene", "Shadow", "Silent",
    "Silver", "Solar", "Sonic", "Spark", "Spectral", "Spirited", "Static", "Stellar",
    "Storm", "Swift", "Titan", "True", "Ultra", "Valiant", "Velvet", "Vibrant",
    "Vivid", "Vortex", "Wild", "Winter", "Wise", "Zenith"
]

NOUNS = [
    "Albatross", "Badger", "Bear", "Beaver", "Bison", "Cheetah", "Condor", "Coyote",
    "Crane", "Dolphin", "Dragon", "Eagle", "Falcon", "Finch", "Fox", "Gazelle",
    "Gecko", "Griffin", "Hawk", "Heron", "Ibex", "Jaguar", "Kestrel", "Koala",
    "Leopard", "Lion", "Lynx", "Mantis", "Marten", "Merlin", "Moose", "Ocelot",
    "Orca", "Osprey", "Otter", "Owl", "Panther", "Pegasus", "Pelican", "Penguin",
    "Phoenix", "Puma", "Python", "Raven", "Rhino", "Robin", "Salamander", "Seagull",
    "Seal", "Shark", "Sparrow", "Stag", "Swan", "Tiger", "Viper", "Walrus",
    "Whale", "Wolf", "Wolverine", "Wombat", "Wren", "Yak", "Zebra"
]


def send_headers(status="200 OK", content_type="application/json; charset=utf-8"):
    headers = [
        f"Status: {status}",
        f"Content-Type: {content_type}",
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: GET, POST, OPTIONS, DELETE",
        "Access-Control-Allow-Headers: Content-Type, Authorization",
        "X-Accel-Buffering: no",
        "Cache-Control: no-cache, no-store, must-revalidate\r\n\r\n",
    ]
    sys.stdout.buffer.write("\r\n".join(headers).encode("utf-8"))
    sys.stdout.buffer.flush()


def get_client_ip():
    forwarded = os.environ.get("HTTP_X_FORWARDED_FOR")
    if forwarded:
        return forwarded.split(",")[0].strip()
    real_ip = os.environ.get("HTTP_X_REAL_IP")
    if real_ip:
        return real_ip.strip()
    return os.environ.get("REMOTE_ADDR", "127.0.0.1").strip()


def ip_to_name(ip: str) -> str:
    ip_clean = (ip or "127.0.0.1").strip().lower()
    h = hashlib.sha256(ip_clean.encode("utf-8")).digest()
    hash_int = int.from_bytes(h[:4], "big")
    adj = ADJECTIVES[hash_int % len(ADJECTIVES)]
    noun = NOUNS[(hash_int // len(ADJECTIVES)) % len(NOUNS)]
    return f"{adj}-{noun}"


def get_db_path():
    env_path = os.environ.get("RESERVATIONS_DB_PATH")
    if env_path:
        parent = os.path.dirname(env_path)
        if parent and not os.path.exists(parent):
            try:
                os.makedirs(parent, exist_ok=True)
            except Exception:
                pass
        return env_path

    for candidate_dir in ["/var/lib/gateway", "/run/model-lock", "/tmp"]:
        if os.path.exists(candidate_dir) and os.access(candidate_dir, os.W_OK):
            return os.path.join(candidate_dir, "reservations.db")

    return "/tmp/reservations.db"


def get_db():
    db_path = get_db_path()
    conn = sqlite3.connect(db_path, timeout=10.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL;")
    conn.execute("PRAGMA busy_timeout = 5000;")
    with conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS reservations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                client_ip TEXT NOT NULL,
                client_name TEXT NOT NULL,
                mode TEXT NOT NULL,          -- 'semaphore', 'timeboxed'
                status TEXT NOT NULL,        -- 'active', 'queued', 'released', 'expired', 'cancelled'
                duration_minutes INTEGER,    -- NULL for semaphore
                created_at REAL NOT NULL,
                started_at REAL,
                expires_at REAL,
                ended_at REAL,
                note TEXT DEFAULT ''
            );
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS recurring_slots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                client_ip TEXT NOT NULL,
                client_name TEXT NOT NULL,
                title TEXT NOT NULL,
                days_of_week TEXT NOT NULL,  -- e.g. "0,1,2,3,4" or "*"
                start_time TEXT NOT NULL,    -- "HH:MM"
                end_time TEXT NOT NULL,      -- "HH:MM"
                created_at REAL NOT NULL
            );
        """)
    return conn


def evaluate_reservations(conn, now=None):
    if now is None:
        now = time.time()

    dt = datetime.datetime.fromtimestamp(now)
    cur_weekday = str(dt.weekday())  # 0=Monday .. 6=Sunday
    cur_time_str = dt.strftime("%H:%M")

    cursor = conn.cursor()
    cursor.execute("SELECT * FROM recurring_slots")
    recurring_rows = cursor.fetchall()

    active_recurring = None
    for r in recurring_rows:
        days = r["days_of_week"]
        is_day_match = (days == "*" or cur_weekday in [d.strip() for d in days.split(",")])
        if is_day_match:
            start_t = r["start_time"]
            end_t = r["end_time"]
            if start_t <= end_t:
                in_slot = (start_t <= cur_time_str < end_t)
            else:
                in_slot = (cur_time_str >= start_t or cur_time_str < end_t)

            if in_slot:
                end_h, end_m = [int(x) for x in end_t.split(":")]
                end_dt = dt.replace(hour=end_h, minute=end_m, second=0, microsecond=0)
                if end_dt.timestamp() <= now:
                    end_dt += datetime.timedelta(days=1)
                active_recurring = {
                    "id": f"recurring-{r['id']}",
                    "recurring_id": r["id"],
                    "client_ip": r["client_ip"],
                    "client_name": r["client_name"],
                    "title": r["title"],
                    "mode": "recurring",
                    "start_time": r["start_time"],
                    "end_time": r["end_time"],
                    "started_at": dt.replace(hour=int(start_t.split(":")[0]), minute=int(start_t.split(":")[1]), second=0).timestamp(),
                    "expires_at": end_dt.timestamp(),
                    "remaining_seconds": max(0, int(end_dt.timestamp() - now)),
                    "note": f"Scheduled daily window: {r['title']}",
                }
                break

    # Check active reservation
    cursor.execute("SELECT * FROM reservations WHERE status = 'active' LIMIT 1")
    current_active = cursor.fetchone()

    if current_active:
        if current_active["mode"] == "timeboxed" and current_active["expires_at"] and now >= current_active["expires_at"]:
            cursor.execute(
                "UPDATE reservations SET status = 'expired', ended_at = ? WHERE id = ?",
                (current_active["expires_at"], current_active["id"]),
            )
            current_active = None

    # If no active holder and no recurring slot, promote earliest queued
    if not current_active and not active_recurring:
        cursor.execute("SELECT * FROM reservations WHERE status = 'queued' ORDER BY created_at ASC LIMIT 1")
        next_queued = cursor.fetchone()
        if next_queued:
            mode = next_queued["mode"]
            started_at = now
            if mode == "timeboxed":
                dur = next_queued["duration_minutes"] or 60
                expires_at = now + (dur * 60)
            else:
                dur = None
                expires_at = None

            cursor.execute(
                "UPDATE reservations SET status = 'active', started_at = ?, expires_at = ? WHERE id = ?",
                (started_at, expires_at, next_queued["id"]),
            )
            cursor.execute("SELECT * FROM reservations WHERE id = ?", (next_queued["id"],))
            current_active = cursor.fetchone()

    # 4. 14-day retention policy: prune inactive records older than 14 days
    retention_cutoff = now - (14 * 86400)
    cursor.execute(
        """DELETE FROM reservations
           WHERE status IN ('released', 'expired', 'cancelled')
             AND COALESCE(ended_at, expires_at, created_at) < ?""",
        (retention_cutoff,),
    )

    conn.commit()
    return current_active, active_recurring


def get_reservations_state(conn, client_ip):
    now = time.time()
    current_active, active_recurring = evaluate_reservations(conn, now)
    client_name = ip_to_name(client_ip)

    cursor = conn.cursor()

    active_info = None
    if active_recurring:
        active_info = active_recurring
    elif current_active:
        remaining = None
        if current_active["expires_at"]:
            remaining = max(0, int(current_active["expires_at"] - now))
        active_info = {
            "id": current_active["id"],
            "client_ip": current_active["client_ip"],
            "client_name": current_active["client_name"],
            "mode": current_active["mode"],
            "duration_minutes": current_active["duration_minutes"],
            "started_at": current_active["started_at"],
            "expires_at": current_active["expires_at"],
            "remaining_seconds": remaining,
            "note": current_active["note"] or "",
        }

    # Queue list
    cursor.execute("SELECT * FROM reservations WHERE status = 'queued' ORDER BY created_at ASC")
    queue_rows = cursor.fetchall()
    queue_list = []
    for q in queue_rows:
        queue_list.append({
            "id": q["id"],
            "client_ip": q["client_ip"],
            "client_name": q["client_name"],
            "mode": q["mode"],
            "duration_minutes": q["duration_minutes"],
            "created_at": q["created_at"],
            "note": q["note"] or "",
        })

    # Recurring slots
    cursor.execute("SELECT * FROM recurring_slots ORDER BY start_time ASC")
    schedule_rows = cursor.fetchall()
    schedule_list = []
    for s in schedule_rows:
        schedule_list.append({
            "id": s["id"],
            "client_ip": s["client_ip"],
            "client_name": s["client_name"],
            "title": s["title"],
            "days_of_week": s["days_of_week"],
            "start_time": s["start_time"],
            "end_time": s["end_time"],
            "created_at": s["created_at"],
        })

    # History list (sessions within the 14-day rolling retention window)
    cursor.execute("""
        SELECT * FROM reservations
        WHERE status IN ('released', 'expired') AND started_at IS NOT NULL
        ORDER BY COALESCE(ended_at, expires_at, started_at) DESC
        LIMIT 100
    """)
    history_rows = cursor.fetchall()
    history_list = []
    for h in history_rows:
        ended = h["ended_at"] or h["expires_at"] or h["started_at"]
        duration_sec = int(ended - h["started_at"]) if ended and h["started_at"] else 0
        history_list.append({
            "id": h["id"],
            "client_name": h["client_name"],
            "mode": h["mode"],
            "status": h["status"],
            "started_at": h["started_at"],
            "ended_at": ended,
            "duration_seconds": duration_sec,
            "note": h["note"] or "",
        })

    is_holder = False
    if active_info and active_info.get("client_ip") == client_ip:
        is_holder = True

    is_queued = False
    queue_position = None
    for idx, item in enumerate(queue_list):
        if item["client_ip"] == client_ip:
            is_queued = True
            queue_position = idx + 1
            break

    return {
        "client": {
            "ip": client_ip,
            "name": client_name,
            "is_holder": is_holder,
            "is_queued": is_queued,
            "queue_position": queue_position,
        },
        "active": active_info,
        "queue": queue_list,
        "schedule": schedule_list,
        "history": history_list,
        "server_time": now,
    }


def main():
    method = os.environ.get("REQUEST_METHOD", "GET")
    if method == "OPTIONS":
        send_headers(status="204 No Content")
        return

    client_ip = get_client_ip()
    conn = get_db()

    raw_uri = os.environ.get("REQUEST_URI", "/")
    path = os.environ.get("PATH_INFO") or raw_uri.split("?")[0]
    clean_path = path.rstrip("/") or "/"

    content_length = int(os.environ.get("CONTENT_LENGTH", 0) or 0)
    body_bytes = sys.stdin.buffer.read(content_length) if content_length > 0 else b""

    data = {}
    if body_bytes:
        try:
            data = json.loads(body_bytes.decode("utf-8"))
        except Exception:
            pass

    # Extract subaction
    subpath = clean_path.replace("/api/reservations", "").replace("/reservations", "").strip("/")
    action = subpath or data.get("action", "")

    now = time.time()

    try:
        if method == "GET" or action in ("", "status", "state"):
            state = get_reservations_state(conn, client_ip)
            send_headers()
            sys.stdout.buffer.write(json.dumps(state).encode("utf-8"))
            sys.stdout.buffer.flush()
            return

        if method == "POST":
            if action == "acquire":
                mode = data.get("mode", "timeboxed")
                duration = data.get("duration", 60)
                note = str(data.get("note", ""))[:256]

                try:
                    duration = int(duration)
                except (ValueError, TypeError):
                    duration = 60
                if duration <= 0 or duration > 1440:
                    duration = 60

                active, recurring = evaluate_reservations(conn, now)
                cursor = conn.cursor()

                if (active and active["client_ip"] == client_ip) or (recurring and recurring["client_ip"] == client_ip):
                    state = get_reservations_state(conn, client_ip)
                    send_headers()
                    sys.stdout.buffer.write(json.dumps({"status": "already_active", "state": state}).encode("utf-8"))
                    sys.stdout.buffer.flush()
                    return

                cursor.execute("SELECT id FROM reservations WHERE status = 'queued' AND client_ip = ? LIMIT 1", (client_ip,))
                if cursor.fetchone():
                    state = get_reservations_state(conn, client_ip)
                    send_headers()
                    sys.stdout.buffer.write(json.dumps({"status": "already_queued", "state": state}).encode("utf-8"))
                    sys.stdout.buffer.flush()
                    return

                client_name = ip_to_name(client_ip)

                if not active and not recurring:
                    # Check for collisions with upcoming scheduled recurring slots
                    dt_now = datetime.datetime.fromtimestamp(now)
                    cur_wday = dt_now.weekday()
                    cursor.execute("SELECT * FROM recurring_slots")
                    all_slots = cursor.fetchall()
                    collision_err = None

                    if mode == "timeboxed":
                        req_end_dt = dt_now + datetime.timedelta(minutes=duration)
                        for s in all_slots:
                            s_days = {0, 1, 2, 3, 4, 5, 6} if s["days_of_week"] == "*" else {int(x) for x in s["days_of_week"].split(",") if x.strip().isdigit()}
                            if cur_wday in s_days:
                                sh, sm = [int(x) for x in s["start_time"].split(":")]
                                eh, em = [int(x) for x in s["end_time"].split(":")]
                                s_start_dt = dt_now.replace(hour=sh, minute=sm, second=0, microsecond=0)
                                s_end_dt = dt_now.replace(hour=eh, minute=em, second=0, microsecond=0)
                                if s_end_dt <= s_start_dt:
                                    s_end_dt += datetime.timedelta(days=1)
                                if max(dt_now, s_start_dt) < min(req_end_dt, s_end_dt):
                                    avail_min = max(0, int((s_start_dt - dt_now).total_seconds() / 60))
                                    collision_err = f"Requested {duration}m collides with scheduled slot '{s['title']}' starting at {s['start_time']}. Maximum available time is {avail_min}m."
                                    break
                    elif mode == "semaphore":
                        cutoff_dt = dt_now + datetime.timedelta(minutes=60)
                        for s in all_slots:
                            s_days = {0, 1, 2, 3, 4, 5, 6} if s["days_of_week"] == "*" else {int(x) for x in s["days_of_week"].split(",") if x.strip().isdigit()}
                            if cur_wday in s_days:
                                sh, sm = [int(x) for x in s["start_time"].split(":")]
                                s_start_dt = dt_now.replace(hour=sh, minute=sm, second=0, microsecond=0)
                                if dt_now <= s_start_dt < cutoff_dt:
                                    collision_err = f"Cannot acquire indefinite semaphore: scheduled recurring slot '{s['title']}' starts at {s['start_time']}."
                                    break

                    if collision_err:
                        send_headers(status="409 Conflict")
                        sys.stdout.buffer.write(json.dumps({"error": collision_err}).encode("utf-8"))
                        sys.stdout.buffer.flush()
                        return

                    started_at = now
                    expires_at = (now + duration * 60) if mode == "timeboxed" else None
                    dur_val = duration if mode == "timeboxed" else None
                    cursor.execute(
                        """INSERT INTO reservations 
                           (client_ip, client_name, mode, status, duration_minutes, created_at, started_at, expires_at, note)
                           VALUES (?, ?, ?, 'active', ?, ?, ?, ?, ?)""",
                        (client_ip, client_name, mode, dur_val, now, started_at, expires_at, note),
                    )
                    conn.commit()
                    res_status = "acquired"
                else:
                    dur_val = duration if mode == "timeboxed" else None
                    cursor.execute(
                        """INSERT INTO reservations 
                           (client_ip, client_name, mode, status, duration_minutes, created_at, note)
                           VALUES (?, ?, ?, 'queued', ?, ?, ?)""",
                        (client_ip, client_name, mode, dur_val, now, note),
                    )
                    conn.commit()
                    res_status = "queued"

                state = get_reservations_state(conn, client_ip)
                send_headers()
                sys.stdout.buffer.write(json.dumps({"status": res_status, "state": state}).encode("utf-8"))
                sys.stdout.buffer.flush()
                return

            elif action == "release":
                force = bool(data.get("force", False))
                cursor = conn.cursor()
                cursor.execute("SELECT * FROM reservations WHERE status = 'active' LIMIT 1")
                active = cursor.fetchone()
                released = False
                if active:
                    if active["client_ip"] == client_ip or force:
                        cursor.execute("UPDATE reservations SET status = 'released', ended_at = ? WHERE id = ?", (now, active["id"]))
                        conn.commit()
                        released = True

                evaluate_reservations(conn, now)
                state = get_reservations_state(conn, client_ip)
                send_headers()
                sys.stdout.buffer.write(json.dumps({"status": "released" if released else "not_held", "state": state}).encode("utf-8"))
                sys.stdout.buffer.flush()
                return

            elif action == "cancel":
                cursor = conn.cursor()
                res_id = data.get("id")
                force = bool(data.get("force", False))
                if res_id:
                    cursor.execute("UPDATE reservations SET status = 'cancelled', ended_at = ? WHERE id = ? AND (client_ip = ? OR ?)", (now, res_id, client_ip, force))
                else:
                    cursor.execute("UPDATE reservations SET status = 'cancelled', ended_at = ? WHERE status = 'queued' AND client_ip = ?", (now, client_ip))
                conn.commit()
                state = get_reservations_state(conn, client_ip)
                send_headers()
                sys.stdout.buffer.write(json.dumps({"status": "cancelled", "state": state}).encode("utf-8"))
                sys.stdout.buffer.flush()
                return

            elif action == "extend":
                minutes = int(data.get("minutes", 30))
                if minutes <= 0 or minutes > 240:
                    minutes = 30
                cursor = conn.cursor()
                cursor.execute("SELECT * FROM reservations WHERE status = 'active' AND client_ip = ? AND mode = 'timeboxed' LIMIT 1", (client_ip,))
                active = cursor.fetchone()
                if active and active["expires_at"]:
                    new_exp = max(now, active["expires_at"]) + (minutes * 60)
                    new_exp_dt = datetime.datetime.fromtimestamp(new_exp)
                    dt_now = datetime.datetime.fromtimestamp(now)
                    cur_wday = dt_now.weekday()

                    # Check collision with upcoming scheduled slots
                    cursor.execute("SELECT * FROM recurring_slots")
                    all_slots = cursor.fetchall()
                    for s in all_slots:
                        s_days = {0, 1, 2, 3, 4, 5, 6} if s["days_of_week"] == "*" else {int(x) for x in s["days_of_week"].split(",") if x.strip().isdigit()}
                        if cur_wday in s_days:
                            sh, sm = [int(x) for x in s["start_time"].split(":")]
                            eh, em = [int(x) for x in s["end_time"].split(":")]
                            s_start_dt = dt_now.replace(hour=sh, minute=sm, second=0, microsecond=0)
                            s_end_dt = dt_now.replace(hour=eh, minute=em, second=0, microsecond=0)
                            if s_end_dt <= s_start_dt:
                                s_end_dt += datetime.timedelta(days=1)
                            if max(dt_now, s_start_dt) < min(new_exp_dt, s_end_dt):
                                avail_min = max(0, int((s_start_dt - datetime.datetime.fromtimestamp(active["expires_at"])).total_seconds() / 60))
                                send_headers(status="409 Conflict")
                                sys.stdout.buffer.write(json.dumps({
                                    "error": f"Cannot extend: collides with scheduled slot '{s['title']}' starting at {s['start_time']}."
                                }).encode("utf-8"))
                                sys.stdout.buffer.flush()
                                return

                    new_dur = (active["duration_minutes"] or 0) + minutes
                    cursor.execute("UPDATE reservations SET expires_at = ?, duration_minutes = ? WHERE id = ?", (new_exp, new_dur, active["id"]))
                    conn.commit()
                state = get_reservations_state(conn, client_ip)
                send_headers()
                sys.stdout.buffer.write(json.dumps({"status": "extended", "state": state}).encode("utf-8"))
                sys.stdout.buffer.flush()
                return

            elif action == "recurring":
                title = str(data.get("title", "")).strip()[:64]
                days = str(data.get("days_of_week", "*")).strip()[:32]
                start_t = str(data.get("start_time", "09:00")).strip()[:5]
                end_t = str(data.get("end_time", "10:00")).strip()[:5]

                if not title:
                    send_headers(status="400 Bad Request")
                    sys.stdout.buffer.write(json.dumps({"error": "Slot title is required."}).encode("utf-8"))
                    sys.stdout.buffer.flush()
                    return

                if start_t >= end_t:
                    send_headers(status="400 Bad Request")
                    sys.stdout.buffer.write(json.dumps({"error": f"Start time ({start_t}) must be earlier than end time ({end_t})."}).encode("utf-8"))
                    sys.stdout.buffer.flush()
                    return

                new_days = {0, 1, 2, 3, 4, 5, 6} if days == "*" else {int(x) for x in days.split(",") if x.strip().isdigit() and 0 <= int(x.strip()) <= 6}
                if not new_days:
                    send_headers(status="400 Bad Request")
                    sys.stdout.buffer.write(json.dumps({"error": "At least one day must be selected."}).encode("utf-8"))
                    sys.stdout.buffer.flush()
                    return

                cursor = conn.cursor()
                cursor.execute("SELECT * FROM recurring_slots")
                existing_slots = cursor.fetchall()
                day_names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

                # Collision check against existing recurring slots
                for s in existing_slots:
                    s_days = {0, 1, 2, 3, 4, 5, 6} if s["days_of_week"] == "*" else {int(x) for x in s["days_of_week"].split(",") if x.strip().isdigit()}
                    common_days = new_days & s_days
                    if common_days:
                        if max(start_t, s["start_time"]) < min(end_t, s["end_time"]):
                            conflict_days_str = ", ".join(day_names[d] for d in sorted(common_days))
                            send_headers(status="409 Conflict")
                            sys.stdout.buffer.write(json.dumps({
                                "error": f"Schedule collision: overlaps with existing slot '{s['title']}' ({s['start_time']} - {s['end_time']}) on {conflict_days_str}."
                            }).encode("utf-8"))
                            sys.stdout.buffer.flush()
                            return

                client_name = ip_to_name(client_ip)
                cursor.execute(
                    """INSERT INTO recurring_slots (client_ip, client_name, title, days_of_week, start_time, end_time, created_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?)""",
                    (client_ip, client_name, title, days, start_t, end_t, now),
                )
                conn.commit()
                state = get_reservations_state(conn, client_ip)
                send_headers()
                sys.stdout.buffer.write(json.dumps({"status": "created", "state": state}).encode("utf-8"))
                sys.stdout.buffer.flush()
                return

            elif action in ("recurring/delete", "delete_recurring"):
                slot_id = data.get("id")
                cursor = conn.cursor()
                if slot_id:
                    cursor.execute("DELETE FROM recurring_slots WHERE id = ?", (slot_id,))
                    conn.commit()
                state = get_reservations_state(conn, client_ip)
                send_headers()
                sys.stdout.buffer.write(json.dumps({"status": "deleted", "state": state}).encode("utf-8"))
                sys.stdout.buffer.flush()
                return

        if method == "DELETE":
            # Support DELETE for recurring slot (e.g. ?id=1)
            query = parse_qs(os.environ.get("QUERY_STRING", ""))
            slot_id = data.get("id") or (query.get("id", [None])[0])
            cursor = conn.cursor()
            if slot_id:
                cursor.execute("DELETE FROM recurring_slots WHERE id = ?", (slot_id,))
                conn.commit()
            state = get_reservations_state(conn, client_ip)
            send_headers()
            sys.stdout.buffer.write(json.dumps({"status": "deleted", "state": state}).encode("utf-8"))
            sys.stdout.buffer.flush()
            return

        send_headers(status="400 Bad Request")
        sys.stdout.buffer.write(json.dumps({"error": f"Unsupported reservation action '{action}'"}).encode("utf-8"))
        sys.stdout.buffer.flush()
    except Exception as e:
        sys.stderr.write(f"Reservation API Error in {clean_path}: {e}\n")
        send_headers(status="500 Internal Server Error")
        sys.stdout.buffer.write(json.dumps({"error": str(e)}).encode("utf-8"))
        sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
