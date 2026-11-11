// Human-readable formatting of registry numbers (card badges, filter labels).

const compact = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });

// 8192 -> "8K", 131072 -> "131K", 1048576 -> "1M". A registry entry may declare no window
// at all (`context = null`), which renders as an em dash instead of a misleading 0.
export function formatTokens(count) {
  return Number.isFinite(count) && count > 0 ? compact.format(count) : "—";
}

export function sessionLabel(sessions) {
  const count = sessions || 1;
  return count === 1 ? "1 session" : `${count} sessions`;
}
