// Trim package-lock.json down to the platform binaries this host actually builds for.
//
// esbuild, @tailwindcss/oxide and @parcel/watcher declare optional bindings for
// ~25 OS/CPU combinations. `prefetch-npm-deps` (npmDepsHash) downloads *every*
// tarball listed in the lockfile, so without this trim a Nix build pulls ~100
// tarballs (several hundred MB of foreign Mach-O/PE binaries) and fails if any
// single one of them hiccups at the registry.
//
// Regenerating the lockfile:
//   npm install --package-lock-only && node scripts/prune-lockfile.mjs
//
// Cross building for another platform: TARGET_OS=aarch64-freebsd node ... etc.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const targetOs = process.env.TARGET_OS ?? "linux";
const targetCpu = process.env.TARGET_CPU ?? "x64";
const lockPath = join(dirname(fileURLToPath(import.meta.url)), "..", "package-lock.json");

const lock = JSON.parse(readFileSync(lockPath, "utf8"));
const fits = (entry) =>
  !entry.optional || (!entry.os || entry.os.includes(targetOs)) && (!entry.cpu || entry.cpu.includes(targetCpu));

const dropped = new Set();
for (const [name, entry] of Object.entries(lock.packages ?? {})) {
  if (name && !fits(entry)) dropped.add(name);
}
// Anything nested below a dropped package goes with it
for (const name of Object.keys(lock.packages ?? {})) {
  for (const gone of dropped) {
    if (name.startsWith(`${gone}/`)) dropped.add(name);
  }
}

for (const name of dropped) delete lock.packages[name];

// Parents must not advertise optional bindings that are no longer in the tree
for (const entry of Object.values(lock.packages ?? {})) {
  for (const section of ["optionalDependencies", "dependencies"]) {
    if (!entry[section]) continue;
    for (const dep of Object.keys(entry[section])) {
      const resolved = `node_modules/${dep}`;
      if (dropped.has(resolved) || [...dropped].some((gone) => resolved.startsWith(`${gone}/`))) {
        delete entry[section][dep];
      }
    }
  }
}

writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`);

const kept = Object.keys(lock.packages ?? {}).length;
console.log(`package-lock.json trimmed for ${targetOs}/${targetCpu}: kept ${kept} packages, dropped ${dropped.size}`);
