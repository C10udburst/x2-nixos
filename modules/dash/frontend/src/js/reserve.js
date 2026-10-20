// LLM Reservation Frontend Coordinator
// Handles Live Control, Week Calendar, Gantt Timeline, and History & Audit views,
// local countdown timer, lightweight state sync, and browser Web Notifications.

import { escapeHtml, setText } from "./dom.js";

const JSON_HEADERS = { "content-type": "application/json" };
let currentState = null;
let activeView = localStorage.getItem("evo_res_view") || "live";
let pollTimer = null;
let clockTimer = null;
let lastKnownRemaining = null;
let lastKnownExpiry = null;
let prevWasQueued = false;
let prevWasHolder = false;

// Audio context synthesizer for turn notification chime
let audioCtx = null;
function playChime() {
  try {
    if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    if (audioCtx.state === "suspended") audioCtx.resume();
    const now = audioCtx.currentTime;

    const osc1 = audioCtx.createOscillator();
    const osc2 = audioCtx.createOscillator();
    const gain = audioCtx.createGain();

    osc1.type = "sine";
    osc2.type = "sine";
    osc1.frequency.setValueAtTime(587.33, now); // D5
    osc1.frequency.exponentialRampToValueAtTime(880, now + 0.15); // A5

    osc2.frequency.setValueAtTime(440, now); // A4
    osc2.frequency.exponentialRampToValueAtTime(659.25, now + 0.15); // E5

    gain.gain.setValueAtTime(0.2, now);
    gain.gain.exponentialRampToValueAtTime(0.001, now + 0.8);

    osc1.connect(gain);
    osc2.connect(gain);
    gain.connect(audioCtx.destination);

    osc1.start(now);
    osc2.start(now);
    osc1.stop(now + 0.85);
    osc2.stop(now + 0.85);
  } catch (_) {
    // Ignore audio autoplay restrictions
  }
}

// Browser Desktop Notification Helper
function initNotifications() {
  const btn = document.getElementById("btn-notify");
  const label = document.getElementById("notify-label");
  const icon = document.getElementById("notify-icon");

  function updateStatus() {
    if (!("Notification" in window)) {
      setText(label, "Unsupported");
      if (btn) btn.disabled = true;
      return;
    }
    if (Notification.permission === "granted") {
      setText(label, "Active");
      if (icon) icon.textContent = "🔔";
      if (btn) btn.classList.add("text-success");
    } else if (Notification.permission === "denied") {
      setText(label, "Blocked");
      if (icon) icon.textContent = "🔕";
      if (btn) btn.classList.add("text-error");
    } else {
      setText(label, "Enable");
      if (icon) icon.textContent = "🔔";
      if (btn) {
        btn.classList.remove("text-success", "text-error");
      }
    }
  }

  if (btn) {
    btn.addEventListener("click", async () => {
      if (!("Notification" in window)) return;
      if (Notification.permission === "default") {
        const perm = await Notification.requestPermission();
        updateStatus();
        if (perm === "granted") {
          showToast("Notifications enabled! You will be alerted when your turn is active.", "success");
          playChime();
        }
      } else if (Notification.permission === "granted") {
        showToast("Browser notifications are already active.", "info");
      } else {
        showToast("Notifications are blocked in your browser settings.", "warning");
      }
    });
  }

  updateStatus();
}

function notifyUser(title, body) {
  playChime();
  if ("Notification" in window && Notification.permission === "granted") {
    try {
      new Notification(title, {
        body,
        icon: "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🤖</text></svg>",
      });
    } catch (_) {}
  }
  showToast(`${title}: ${body}`, "info");
}

function showToast(message, type = "info") {
  const el = document.getElementById("toast");
  if (!el) return;
  el.className = `alert alert-${type} fixed bottom-4 right-4 z-50 shadow-xl max-w-sm transition-all`;
  el.textContent = message;
  el.classList.remove("hidden");
  clearTimeout(el._timer);
  el._timer = setTimeout(() => {
    el.classList.add("hidden");
  }, 4500);
}

// API Calls
async function fetchState() {
  const res = await fetch("/api/reservations", { cache: "no-store" });
  if (!res.ok) throw new Error(`/api/reservations -> ${res.status}`);
  return res.json();
}

async function postReservation(action, payload = {}) {
  const res = await fetch(`/api/reservations/${action}`, {
    method: "POST",
    headers: JSON_HEADERS,
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.error || `Action ${action} failed: ${res.status}`);
  }
  return res.json();
}

// Format Seconds -> "HH:MM:SS" or "MM:SS"
function formatDuration(sec) {
  if (sec == null || isNaN(sec) || sec < 0) return "--:--:--";
  const s = Math.floor(sec % 60);
  const m = Math.floor((sec / 60) % 60);
  const h = Math.floor(sec / 3600);
  if (h > 0) {
    return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  }
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

function formatMinutes(min) {
  if (!min) return "Indefinite";
  if (min >= 60) {
    const h = Math.floor(min / 60);
    const m = min % 60;
    return m ? `${h}h ${m}m` : `${h}h`;
  }
  return `${min}m`;
}

// -----------------------------------------------------------------------------
// RENDERERS
// -----------------------------------------------------------------------------

function renderLiveView(state) {
  const isHolder = state.client.is_holder;
  const isQueued = state.client.is_queued;
  const active = state.active;

  // Header identity badge
  setText(document.getElementById("my-identity"), `${state.client.name} (${state.client.ip})`);

  // Elements
  const liveBadge = document.getElementById("live-badge");
  const liveModeBadge = document.getElementById("live-mode-badge");
  const holderTitle = document.getElementById("live-holder-title");
  const holderDesc = document.getElementById("live-holder-desc");
  const btnRelease = document.getElementById("btn-release");
  const btnExtend = document.getElementById("btn-extend");
  const btnSubmit = document.getElementById("btn-submit-reserve");
  const idleActions = document.getElementById("idle-quick-actions");
  const queueBanner = document.getElementById("queue-status-banner");

  if (active) {
    const isRecurring = active.mode === "recurring";
    if (isRecurring) {
      setText(liveBadge, "Scheduled Slot");
      liveBadge.className = "badge badge-primary font-semibold uppercase text-xs";
      setText(liveModeBadge, "Recurring");
      setText(holderTitle, active.title || "Scheduled Daily Window");
      setText(holderDesc, `Reserved for ${active.client_name} • ${active.start_time} - ${active.end_time}`);
    } else {
      setText(liveBadge, "Reserved");
      liveBadge.className = "badge badge-warning font-semibold uppercase text-xs";
      setText(liveModeBadge, active.mode === "semaphore" ? "Semaphore" : `Timeboxed (${formatMinutes(active.duration_minutes)})`);
      const alias = active.client_name;
      setText(holderTitle, isHolder ? `${alias} (You)` : alias);
      setText(holderDesc, active.note ? `Note: "${active.note}"` : "Active exclusive lease on EVO-X2.");
    }

    if (btnRelease) btnRelease.disabled = !isHolder;
    if (btnExtend) btnExtend.disabled = !isHolder || active.mode !== "timeboxed";
    if (idleActions) idleActions.classList.add("hidden");

    if (btnSubmit) {
      setText(btnSubmit, "Join Waitlist Queue");
      btnSubmit.className = "btn btn-outline btn-primary btn-sm mt-2 font-mono";
    }

    lastKnownRemaining = active.remaining_seconds;
    lastKnownExpiry = active.expires_at;
  } else {
    // Machine is idle / available
    setText(liveBadge, "Available");
    liveBadge.className = "badge badge-success font-semibold uppercase text-xs";
    setText(liveModeBadge, "Idle");
    setText(holderTitle, "Machine Available");
    setText(holderDesc, "No active reservation. You can acquire an exclusive lock or time slot now.");

    if (btnRelease) btnRelease.disabled = true;
    if (btnExtend) btnExtend.disabled = true;
    if (idleActions) idleActions.classList.remove("hidden");

    if (btnSubmit) {
      setText(btnSubmit, "Acquire Exclusive Lock");
      btnSubmit.className = "btn btn-primary btn-sm mt-2 font-mono";
    }

    lastKnownRemaining = null;
    lastKnownExpiry = null;
    setText(document.getElementById("live-timer"), "--:--:--");
    setText(document.getElementById("live-timer-sub"), "Ready for immediate lock");
  }

  // Queue banner for current user
  if (queueBanner) {
    if (isQueued) {
      queueBanner.classList.remove("hidden");
      const posText = queueBanner.querySelector("span");
      if (posText) posText.textContent = `⏳ You are #${state.client.queue_position} in the waitlist!`;
    } else {
      queueBanner.classList.add("hidden");
    }
  }

  // Render Waitlist Queue
  const queueCountBadge = document.getElementById("queue-count-badge");
  const queueEmptyMsg = document.getElementById("queue-empty-msg");
  const queueList = document.getElementById("queue-items-list");

  setText(queueCountBadge, `${state.queue.length} waiting`);

  if (!state.queue || state.queue.length === 0) {
    if (queueEmptyMsg) queueEmptyMsg.classList.remove("hidden");
    if (queueList) queueList.innerHTML = "";
  } else {
    if (queueEmptyMsg) queueEmptyMsg.classList.add("hidden");
    if (queueList) {
      queueList.innerHTML = state.queue
        .map((item, idx) => {
          const isMe = item.client_ip === state.client.ip;
          const modeLabel = item.mode === "semaphore" ? "Semaphore" : `${formatMinutes(item.duration_minutes)}`;
          return `
            <div class="flex flex-wrap items-center justify-between gap-2 rounded-box border ${
              isMe ? "border-primary bg-primary/10" : "border-base-300 bg-base-100"
            } p-3 text-xs">
              <div class="flex items-center gap-2">
                <span class="badge ${isMe ? "badge-primary" : "badge-neutral"} font-mono text-xs font-bold">#${idx + 1}</span>
                <div class="flex flex-col">
                  <span class="font-mono font-bold">${escapeHtml(item.client_name)} ${
            isMe ? '<span class="text-primary font-semibold">(You)</span>' : ""
          }</span>
                  <span class="opacity-60 text-[11px]">${escapeHtml(item.note || "No note provided")}</span>
                </div>
              </div>
              <div class="flex items-center gap-2">
                <span class="badge badge-outline font-mono text-[11px]">${modeLabel}</span>
                ${
                  isMe
                    ? `<button class="btn btn-error btn-xs btn-outline font-mono" onclick="window.leaveWaitlist()">Leave</button>`
                    : ""
                }
              </div>
            </div>
          `;
        })
        .join("");
    }
  }
}

// View 2: Week-at-a-Glance 24h Visual Block View
function renderCalendarView(state) {
  const container = document.getElementById("calendar-grid");
  if (!container) return;

  const dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  const now = new Date(state.server_time * 1000);
  const curWeekday = (now.getDay() + 6) % 7; // Mon=0 .. Sun=6

  // 8-column grid: 1 col for time labels, 7 cols for days
  let html = `
    <div class="grid grid-cols-8 border-b border-base-300 bg-base-300/40 text-center font-mono text-xs py-2">
      <div class="opacity-50">Time</div>
      ${dayNames
        .map(
          (d, idx) => `
        <div class="${idx === curWeekday ? "text-primary font-bold underline" : "opacity-80"}">
          ${d} ${idx === curWeekday ? '<span class="text-[10px] block opacity-60">Today</span>' : ""}
        </div>
      `,
        )
        .join("")}
    </div>
    <div class="relative grid grid-cols-8 divide-x divide-base-300 text-xs font-mono">
  `;

  // Time rows (24 hours in 2-hour increments)
  const hours = [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22];

  html += `<div class="flex flex-col divide-y divide-base-300 opacity-50 bg-base-200/50">`;
  for (const h of hours) {
    html += `<div class="h-12 flex items-center justify-center text-[10px]">${String(h).padStart(2, "0")}:00</div>`;
  }
  html += `</div>`;

  // For each day (0..6), render slot blocks
  for (let dayIdx = 0; dayIdx < 7; dayIdx++) {
    html += `<div class="relative h-[288px] border-b border-base-300 bg-base-100">`;

    // Render recurring slots matching this day
    for (const slot of state.schedule || []) {
      const days = slot.days_of_week;
      const isDayMatch = days === "*" || days.split(",").map((s) => s.trim()).includes(String(dayIdx));
      if (isDayMatch) {
        const [sh, sm] = slot.start_time.split(":").map(Number);
        const [eh, em] = slot.end_time.split(":").map(Number);
        const startMin = sh * 60 + sm;
        const endMin = (eh < sh ? eh + 24 : eh) * 60 + em;
        const topPct = (startMin / 1440) * 100;
        const heightPct = Math.max(4, ((endMin - startMin) / 1440) * 100);

        html += `
          <div class="absolute left-1 right-1 rounded bg-primary/25 border border-primary text-primary-content p-1 overflow-hidden shadow-sm hover:z-20 cursor-default"
            style="top: ${topPct.toFixed(1)}%; height: ${heightPct.toFixed(1)}%;"
            title="${escapeHtml(slot.title)} (${slot.start_time} - ${slot.end_time}) by ${escapeHtml(slot.client_name)}">
            <span class="font-bold block text-[10px] leading-tight text-primary truncate">${escapeHtml(slot.title)}</span>
            <span class="text-[9px] opacity-75 block text-primary truncate">${slot.start_time}-${slot.end_time}</span>
          </div>
        `;
      }
    }

    // If day is today and active lease is running, render active block
    if (dayIdx === curWeekday && state.active) {
      const act = state.active;
      const startD = new Date(act.started_at * 1000);
      const startMin = startD.getHours() * 60 + startD.getMinutes();
      let durMin = act.duration_minutes || 60;
      if (act.expires_at) {
        durMin = Math.max(15, Math.round((act.expires_at - act.started_at) / 60));
      }
      const topPct = (startMin / 1440) * 100;
      const heightPct = Math.max(5, (durMin / 1440) * 100);

      html += `
        <div class="absolute left-1 right-1 rounded bg-warning/30 border border-warning text-warning-content p-1 overflow-hidden shadow-sm hover:z-20 animate-pulse"
          style="top: ${topPct.toFixed(1)}%; height: ${heightPct.toFixed(1)}%;"
          title="Active Lease: ${escapeHtml(act.client_name)} (${durMin}m)">
          <span class="font-bold block text-[10px] leading-tight text-warning truncate">Active: ${escapeHtml(act.client_name)}</span>
          <span class="text-[9px] opacity-80 block text-warning truncate">Live lease</span>
        </div>
      `;
    }

    html += `</div>`;
  }

  html += `</div>`;
  container.innerHTML = html;

  // Render Recurring Schedule Table
  const table = document.getElementById("schedule-table");
  const tableEmpty = document.getElementById("schedule-table-empty");
  const tbody = document.getElementById("schedule-table-body");

  if (!state.schedule || state.schedule.length === 0) {
    if (table) table.classList.add("hidden");
    if (tableEmpty) tableEmpty.classList.remove("hidden");
  } else {
    if (tableEmpty) tableEmpty.classList.add("hidden");
    if (table) table.classList.remove("hidden");
    if (tbody) {
      tbody.innerHTML = state.schedule
        .map((s) => {
          let dayLabel = "Daily";
          if (s.days_of_week === "0,1,2,3,4") dayLabel = "Mon-Fri";
          else if (s.days_of_week !== "*") {
            dayLabel = s.days_of_week
              .split(",")
              .map((d) => dayNames[Number(d.trim())])
              .join(", ");
          }
          return `
            <tr class="hover:bg-base-300/40">
              <td class="font-bold text-base-content">${escapeHtml(s.title)}</td>
              <td><span class="badge badge-neutral badge-xs">${dayLabel}</span></td>
              <td>${s.start_time} - ${s.end_time}</td>
              <td class="text-primary">${escapeHtml(s.client_name)}</td>
              <td>
                <button class="btn btn-ghost btn-xs text-error" onclick="window.deleteRecurring(${s.id})">Delete</button>
              </td>
            </tr>
          `;
        })
        .join("");
    }
  }
}

// View 3: Continuous 24h Gantt Timeline Strip
function renderTimelineView(state) {
  const axis = document.getElementById("gantt-axis");
  const track = document.getElementById("gantt-track");
  const breakdown = document.getElementById("gantt-breakdown");
  if (!track || !axis || !breakdown) return;

  const nowEpoch = state.server_time;
  const horizonSeconds = 24 * 3600;

  // Build Axis ticks: Now, +3h, +6h, +9h, +12h, +15h, +18h, +21h, +24h
  const tickHours = [0, 3, 6, 9, 12, 15, 18, 21, 24];
  axis.innerHTML = tickHours
    .map((h) => {
      const d = new Date((nowEpoch + h * 3600) * 1000);
      const timeStr = `${String(d.getHours()).padStart(2, "0")}:00`;
      return `<span>${h === 0 ? "Now" : `+${h}h (${timeStr})`}</span>`;
    })
    .join("");

  // Build segments on the track
  let trackHtml = "";
  const events = [];
  let currentOffsetSec = 0;

  // 1. Current Active Lease
  if (state.active) {
    const act = state.active;
    const durSec = act.remaining_seconds != null ? act.remaining_seconds : 3600; // 1h if indefinite
    const widthPct = Math.min(100, (durSec / horizonSeconds) * 100);

    events.push({
      type: "active",
      title: act.mode === "recurring" ? act.title : act.client_name,
      subtitle: `Active Lease (${formatDuration(durSec)})`,
      width: widthPct,
      color: "bg-warning text-warning-content",
      badgeColor: "badge-warning",
    });

    currentOffsetSec += durSec;
  }

  // 2. Projected Queue Sequence
  for (const q of state.queue || []) {
    const durSec = (q.duration_minutes || 60) * 60;
    if (currentOffsetSec >= horizonSeconds) break;
    const startOffset = currentOffsetSec;
    const remainingInHorizon = horizonSeconds - startOffset;
    const effDurSec = Math.min(durSec, remainingInHorizon);
    const widthPct = (effDurSec / horizonSeconds) * 100;

    events.push({
      type: "queued",
      title: q.client_name,
      subtitle: `Projected Turn (${formatMinutes(q.duration_minutes)})`,
      width: widthPct,
      color: "bg-info text-info-content",
      badgeColor: "badge-info",
    });

    currentOffsetSec += effDurSec;
  }

  // 3. Upcoming Scheduled Locks (from recurring slots within next 24h)
  const nowDate = new Date(nowEpoch * 1000);
  for (const r of state.schedule || []) {
    // Check if slot falls in next 24 hours
    const [sh, sm] = r.start_time.split(":").map(Number);
    const [eh, em] = r.end_time.split(":").map(Number);
    const durMin = (eh < sh ? eh + 24 : eh) * 60 + em - (sh * 60 + sm);

    // Check today and tomorrow
    for (let dayOffset = 0; dayOffset <= 1; dayOffset++) {
      const d = new Date((nowEpoch + dayOffset * 86400) * 1000);
      const wday = String((d.getDay() + 6) % 7);
      if (r.days_of_week === "*" || r.days_of_week.split(",").includes(wday)) {
        const slotStart = new Date(d);
        slotStart.setHours(sh, sm, 0, 0);
        const slotStartEpoch = slotStart.getTime() / 1000;
        const offsetSec = slotStartEpoch - nowEpoch;

        if (offsetSec >= 0 && offsetSec < horizonSeconds) {
          const widthPct = (durMin * 60 / horizonSeconds) * 100;
          const leftPct = (offsetSec / horizonSeconds) * 100;

          // Render as overlay bar on track
          trackHtml += `
            <div class="absolute top-0 bottom-0 rounded bg-primary/70 border border-primary text-primary-content text-[10px] font-bold p-1 overflow-hidden shadow z-10 truncate"
              style="left: ${leftPct.toFixed(1)}%; width: ${Math.max(2, widthPct).toFixed(1)}%;"
              title="Scheduled: ${escapeHtml(r.title)} (${r.start_time} - ${r.end_time})">
              ${escapeHtml(r.title)}
            </div>
          `;
        }
      }
    }
  }

  // Render sequential blocks onto track
  trackHtml += events
    .map(
      (ev) => `
    <div class="h-full flex items-center justify-center font-mono font-bold text-xs ${ev.color} border-r border-base-200 px-1 truncate shadow-sm"
      style="width: ${ev.width.toFixed(2)}%;"
      title="${escapeHtml(ev.title)} • ${ev.subtitle}">
      <span class="truncate">${escapeHtml(ev.title)}</span>
    </div>
  `,
    )
    .join("");

  // Remaining open availability
  const freePct = Math.max(0, 100 - events.reduce((sum, e) => sum + e.width, 0));
  if (freePct > 0) {
    trackHtml += `
      <div class="h-full flex items-center justify-center font-mono text-xs opacity-40 bg-base-300 px-2"
        style="width: ${freePct.toFixed(2)}%;">
        <span>Open Availability</span>
      </div>
    `;
  }

  track.innerHTML = trackHtml;

  // Itemized sequence cards
  if (events.length === 0 && (!state.schedule || state.schedule.length === 0)) {
    breakdown.innerHTML = `<div class="col-span-3 text-xs opacity-50 py-3">No upcoming locks. Workload is free for the next 24 hours.</div>`;
  } else {
    breakdown.innerHTML = events
      .map(
        (ev) => `
      <div class="card bg-base-100 border border-base-300 p-3 shadow-sm">
        <div class="flex items-center justify-between">
          <span class="badge ${ev.badgeColor} badge-sm font-mono text-[11px]">${ev.type}</span>
          <span class="text-xs font-mono font-bold">${escapeHtml(ev.title)}</span>
        </div>
        <p class="text-[11px] opacity-60 mt-1">${ev.subtitle}</p>
      </div>
    `,
      )
      .join("");
  }
}

// View 4: Machine Utilization & Audit Log Table
function renderHistoryView(state) {
  const history = state.history || [];
  const tbody = document.getElementById("history-table-body");
  const statTotalSessions = document.getElementById("stat-total-sessions");
  const statTotalHours = document.getElementById("stat-total-hours");
  const statLastClient = document.getElementById("stat-last-client");

  // Compute metrics
  setText(statTotalSessions, String(history.length));
  const totalSeconds = history.reduce((sum, h) => sum + (h.duration_seconds || 0), 0);
  const totalHours = (totalSeconds / 3600).toFixed(1);
  setText(statTotalHours, `${totalHours}h`);
  setText(statLastClient, history.length > 0 ? history[0].client_name : "None");

  if (!tbody) return;

  if (history.length === 0) {
    tbody.innerHTML = `<tr><td colspan="6" class="text-center py-6 opacity-40">No past sessions recorded yet.</td></tr>`;
    return;
  }

  tbody.innerHTML = history
    .map((h) => {
      const endedDate = h.ended_at ? new Date(h.ended_at * 1000).toLocaleString() : "Unknown";
      const durStr = formatDuration(h.duration_seconds);
      const isReleasedEarly = h.status === "released";
      const statusBadge = isReleasedEarly
        ? `<span class="badge badge-success badge-xs">Released early</span>`
        : `<span class="badge badge-neutral badge-xs">Completed</span>`;

      return `
        <tr class="hover:bg-base-300/40">
          <td class="text-xs">${endedDate}</td>
          <td class="font-bold text-primary">${escapeHtml(h.client_name)}</td>
          <td><span class="badge badge-outline badge-xs">${h.mode}</span></td>
          <td class="font-mono">${durStr}</td>
          <td>${statusBadge}</td>
          <td class="opacity-70 text-xs">${escapeHtml(h.note || "—")}</td>
        </tr>
      `;
    })
    .join("");
}

// -----------------------------------------------------------------------------
// MAIN STATE SYNC & TIMERS
// -----------------------------------------------------------------------------

async function syncState() {
  try {
    const state = await fetchState();
    currentState = state;

    // Detect Turn Active: transition from queued -> holder
    const isNowHolder = state.client.is_holder;
    const isNowQueued = state.client.is_queued;

    if (prevWasQueued && isNowHolder) {
      notifyUser("Workload Ready!", `Your turn has arrived! You now hold exclusive access as ${state.client.name}.`);
    } else if (prevWasHolder && !isNowHolder) {
      notifyUser("Reservation Expired", "Your reserved time slot on EVO-X2 has ended.");
    }

    prevWasQueued = isNowQueued;
    prevWasHolder = isNowHolder;

    // Render current active view
    renderActiveView(state);

    const statusDot = document.getElementById("status-dot");
    if (statusDot) {
      statusDot.className = "status status-lg status-success animate-pulse tooltip tooltip-left";
      statusDot.setAttribute("data-tip", "Reservation system live");
    }
  } catch (err) {
    const statusDot = document.getElementById("status-dot");
    if (statusDot) {
      statusDot.className = "status status-lg status-error tooltip tooltip-left";
      statusDot.setAttribute("data-tip", "Sync failed: " + err.message);
    }
  }
}

function renderActiveView(state) {
  if (!state) return;
  renderLiveView(state);
  if (activeView === "calendar") renderCalendarView(state);
  else if (activeView === "timeline") renderTimelineView(state);
  else if (activeView === "history") renderHistoryView(state);
}

function setupLocalClock() {
  if (clockTimer) clearInterval(clockTimer);
  clockTimer = setInterval(() => {
    if (lastKnownExpiry != null) {
      const nowEpoch = Date.now() / 1000;
      const left = Math.max(0, Math.round(lastKnownExpiry - nowEpoch));
      const el = document.getElementById("live-timer");
      if (el) el.textContent = formatDuration(left);

      // If timer reaches zero, trigger immediate server-side state evaluation
      if (left === 0 && lastKnownRemaining !== 0) {
        lastKnownRemaining = 0;
        syncState();
      }
    }
  }, 1000);
}

function setupPolling() {
  if (pollTimer) clearInterval(pollTimer);
  // Adaptive polling: 4s when active, 15s when hidden
  const interval = document.hidden ? 15000 : 4000;
  pollTimer = setInterval(syncState, interval);
}

document.addEventListener("visibilitychange", () => {
  setupPolling();
  if (!document.hidden) {
    syncState(); // Wakeup immediately on tab focus
  }
});

// -----------------------------------------------------------------------------
// EVENT HANDLERS
// -----------------------------------------------------------------------------

function setupViewSwitcher() {
  const buttons = document.querySelectorAll("[data-view-btn]");
  const views = ["live", "calendar", "timeline", "history"];

  function switchView(viewName) {
    activeView = viewName;
    localStorage.setItem("evo_res_view", viewName);

    buttons.forEach((btn) => {
      const match = btn.getAttribute("data-view-btn") === viewName;
      btn.classList.toggle("btn-active", match);
    });

    views.forEach((v) => {
      const el = document.getElementById(`view-${v}`);
      if (el) el.classList.toggle("hidden", v !== viewName);
    });

    if (currentState) {
      renderActiveView(currentState);
    }
  }

  buttons.forEach((btn) => {
    btn.addEventListener("click", () => {
      switchView(btn.getAttribute("data-view-btn"));
    });
  });

  switchView(activeView);
}

function setupFormHandlers() {
  // Duration chips for Time-Boxed
  const chips = document.querySelectorAll(".duration-chip");
  const customDurInput = document.getElementById("custom-duration");
  chips.forEach((c) => {
    c.addEventListener("click", () => {
      chips.forEach((x) => {
        x.classList.remove("btn-primary");
        x.classList.add("btn-outline");
      });
      c.classList.remove("btn-outline");
      c.classList.add("btn-primary");
      if (customDurInput) customDurInput.value = c.getAttribute("data-min");
    });
  });

  // Mode radio toggle
  const modeRadios = document.querySelectorAll('input[name="res-mode"]');
  const durSelector = document.getElementById("duration-selector");
  modeRadios.forEach((r) => {
    r.addEventListener("change", () => {
      if (durSelector) {
        durSelector.classList.toggle("hidden", r.value === "semaphore" && r.checked);
      }
    });
  });

  // Acquire / Join Waitlist Submit
  const formReserve = document.getElementById("form-reserve");
  if (formReserve) {
    formReserve.addEventListener("submit", async (e) => {
      e.preventDefault();
      const mode = document.querySelector('input[name="res-mode"]:checked')?.value || "timeboxed";
      const duration = parseInt(customDurInput?.value || "60", 10);
      const note = document.getElementById("reserve-note")?.value?.trim() || "";

      try {
        const res = await postReservation("acquire", { mode, duration, note });
        if (res.status === "acquired") {
          showToast("Exclusive lock acquired!", "success");
          playChime();
        } else if (res.status === "queued") {
          showToast(`Queued at position #${res.state?.client?.queue_position}`, "info");
        } else if (res.status === "already_active") {
          showToast("You already hold the active reservation.", "info");
        }
        await syncState();
      } catch (err) {
        showToast(err.message, "error");
      }
    });
  }

  // Quick 1h & Quick Semaphore buttons
  const btnQuick1h = document.getElementById("btn-quick-1h");
  if (btnQuick1h) {
    btnQuick1h.addEventListener("click", async () => {
      try {
        await postReservation("acquire", { mode: "timeboxed", duration: 60, note: "Quick 1h reservation" });
        showToast("1-hour reservation acquired!", "success");
        await syncState();
      } catch (err) {
        showToast(err.message, "error");
      }
    });
  }

  const btnQuickSem = document.getElementById("btn-quick-sem");
  if (btnQuickSem) {
    btnQuickSem.addEventListener("click", async () => {
      try {
        await postReservation("acquire", { mode: "semaphore", note: "Indefinite exclusive semaphore" });
        showToast("Indefinite lock acquired!", "success");
        await syncState();
      } catch (err) {
        showToast(err.message, "error");
      }
    });
  }

  // Release button
  const btnRelease = document.getElementById("btn-release");
  if (btnRelease) {
    btnRelease.addEventListener("click", async () => {
      if (!confirm("Release your reservation early?")) return;
      try {
        await postReservation("release");
        showToast("Reservation released early.", "info");
        await syncState();
      } catch (err) {
        showToast(err.message, "error");
      }
    });
  }

  // Extend button (+30m)
  const btnExtend = document.getElementById("btn-extend");
  if (btnExtend) {
    btnExtend.addEventListener("click", async () => {
      try {
        await postReservation("extend", { minutes: 30 });
        showToast("Reservation extended by 30 minutes.", "success");
        await syncState();
      } catch (err) {
        showToast(err.message, "error");
      }
    });
  }

  // Leave queue from banner
  const btnLeaveQueue = document.getElementById("btn-leave-queue");
  if (btnLeaveQueue) {
    btnLeaveQueue.addEventListener("click", async () => {
      window.leaveWaitlist();
    });
  }

  // Recurring Modal
  const btnOpenRec = document.getElementById("btn-open-recurring-modal");
  const modalRec = document.getElementById("modal-recurring");
  if (btnOpenRec && modalRec) {
    btnOpenRec.addEventListener("click", () => modalRec.showModal());
  }

  const formRec = document.getElementById("form-recurring");
  if (formRec) {
    formRec.addEventListener("submit", async (e) => {
      e.preventDefault();
      const title = document.getElementById("recurring-title")?.value?.trim();
      const start = document.getElementById("recurring-start")?.value;
      const end = document.getElementById("recurring-end")?.value;
      const checkedDays = Array.from(document.querySelectorAll('input[name="rec-day"]:checked')).map((c) => c.value);

      if (!title || !start || !end) return;
      const daysStr = checkedDays.length === 7 ? "*" : checkedDays.join(",");

      try {
        await postReservation("recurring", {
          title,
          days_of_week: daysStr,
          start_time: start,
          end_time: end,
        });
        showToast("Recurring window created!", "success");
        if (modalRec) modalRec.close();
        formRec.reset();
        await syncState();
      } catch (err) {
        showToast(err.message, "error");
      }
    });
  }
}

// Window global functions for inlined HTML event handlers
window.leaveWaitlist = async function () {
  try {
    await postReservation("cancel");
    showToast("Left waitlist queue.", "info");
    await syncState();
  } catch (err) {
    showToast(err.message, "error");
  }
};

window.deleteRecurring = async function (id) {
  if (!confirm("Delete this recurring schedule slot?")) return;
  try {
    await postReservation("recurring/delete", { id });
    showToast("Recurring slot deleted.", "info");
    await syncState();
  } catch (err) {
    showToast(err.message, "error");
  }
};

// -----------------------------------------------------------------------------
// INIT
// -----------------------------------------------------------------------------

initNotifications();
setupViewSwitcher();
setupFormHandlers();
setupLocalClock();
setupPolling();

// Initial sync
syncState();
