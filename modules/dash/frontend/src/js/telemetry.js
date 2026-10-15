// Maps the /api/status payload onto the telemetry charts.

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

    points.gtt = gtt;
    points.vram = vram;

    if (gpu.gtt_total_mb > 0) {
      subs.vram = `GTT ${round(gtt)} / ${round(gpu.gtt_total_mb / GB, 0)} GB • VRAM ${round(vram)} GB`;
    } else if (gpu.vram_total_mb > 0) {
      subs.vram = `VRAM ${round(vram)} / ${round(gpu.vram_total_mb / GB, 0)} GB • GTT ${round(gtt)} GB`;
    } else {
      subs.vram = `Dynamic unified GTT allocation • VRAM ${round(vram)} GB`;
    }

    points.gpu = gpu.busy_percent ?? 0;
    if (Number.isFinite(gpu.temp_c)) {
      points.gpu_temp = gpu.temp_c;
    } else if (Number.isFinite(data.temperatures?.gpu_c)) {
      points.gpu_temp = data.temperatures.gpu_c;
    }
  }

  const cpu = data.cpu;
  if (cpu) {
    points.cpu = cpu.busy_percent ?? 0;
    if (Number.isFinite(cpu.temp_c)) {
      points.cpu_temp = cpu.temp_c;
    } else if (Number.isFinite(data.temperatures?.cpu_c)) {
      points.cpu_temp = data.temperatures.cpu_c;
    }
  } else if (Array.isArray(data.load_avg)) {
    const [one] = data.load_avg;
    points.cpu = Math.min(100, Math.round((one / 32) * 100));
    if (Number.isFinite(data.temperatures?.cpu_c)) {
      points.cpu_temp = data.temperatures.cpu_c;
    }
  }

  if (Array.isArray(data.load_avg)) {
    const [one, five, fifteen] = data.load_avg;
    subs.load = `1m: ${round(one, 2)} • 5m: ${round(five, 2)} • GPU busy: ${round(points.gpu ?? 0, 0)}%`;
  } else {
    subs.load = `CPU: ${round(points.cpu ?? 0, 0)}% • GPU: ${round(points.gpu ?? 0, 0)}%`;
  }

  const cpuTempStr = Number.isFinite(points.cpu_temp) ? `${round(points.cpu_temp, 0)}°C` : "--";
  const gpuTempStr = Number.isFinite(points.gpu_temp) ? `${round(points.gpu_temp, 0)}°C` : "--";
  subs.temp = `CPU ${cpuTempStr} (Tctl) • GPU ${gpuTempStr} (edge)`;

  return { points, subs };
}
