// Maps the /api/status payload onto the four telemetry charts.

const GB = 1024; // payload is in MB

const round = (value, digits = 1) => Number(value).toFixed(digits);

export function readTelemetry(data) {
  const points = {};
  const subs = {};

  const memory = data.memory;
  if (memory) {
    points.ram = memory.used_mb / GB;
    subs.ram = `${round(points.ram)} / ${round(memory.total_mb / GB, 0)} GB • ${memory.percent_used}% used`;
  }

  const gpu = data.gpu;
  if (gpu) {
    const vram = gpu.vram_used_mb / GB;
    const gtt = gpu.gtt_used_mb / GB;

    // On the Ryzen AI Max+ APU the GTT aperture is the real VRAM allocation pool.
    if (gpu.gtt_total_mb > 0) {
      points.vram = gtt;
      subs.vram = `GTT ${round(gtt)} / ${round(gpu.gtt_total_mb / GB, 0)} GB • VRAM ${round(vram)} GB`;
    } else if (gpu.vram_total_mb > 0) {
      points.vram = vram;
      subs.vram = `VRAM ${round(vram)} / ${round(gpu.vram_total_mb / GB, 0)} GB • GTT ${round(gtt)} GB`;
    } else {
      points.vram = gtt;
      subs.vram = `Dynamic unified GTT allocation • VRAM ${round(vram)} GB`;
    }

    points.gpu = gpu.busy_percent ?? 0;
    subs.gpu = gpu.device || "AMD Radeon Graphics";
  }

  if (Array.isArray(data.load_avg)) {
    const [one, five, fifteen] = data.load_avg;
    points.cpu = one;
    subs.cpu = `1m ${round(one, 2)} • 5m ${round(five, 2)} • 15m ${round(fifteen, 2)}`;
  }

  return { points, subs };
}
