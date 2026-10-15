// Build: esbuild bundles the ES modules, the Tailwind CLI compiles daisyUI 5
// (halloween theme only), and index.html gets content-hashed asset references.
// Output layout: dist/index.html + dist/assets/app.<hash>.{js,css}

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";

const projectRoot = dirname(fileURLToPath(import.meta.url));
const srcDir = join(projectRoot, "src");
const outDir = resolve(process.env.DIST_DIR ?? join(projectRoot, "dist"));
const assetsDir = join(outDir, "assets");
const tailwindBin = process.env.TAILWIND_BIN ?? join(projectRoot, "node_modules/.bin/tailwindcss");

const contentHash = (contents) => createHash("sha256").update(contents).digest("base64url").slice(0, 10);

await rm(outDir, { recursive: true, force: true });
await mkdir(assetsDir, { recursive: true });

const jsBuild = await esbuild.build({
  absWorkingDir: projectRoot,
  entryPoints: ["src/js/main.js"],
  bundle: true,
  format: "esm",
  target: "es2022",
  minify: true,
  legalComments: "none",
  metafile: true,
  write: false,
});
const jsCode = jsBuild.outputFiles[0].text;
const jsFile = `app.${contentHash(jsCode)}.js`;
await writeFile(join(assetsDir, jsFile), jsCode);

const unhashedCss = join(assetsDir, "unhashed.css");
execFileSync(tailwindBin, ["-i", "src/css/app.css", "-o", unhashedCss, "--minify"], {
  cwd: projectRoot,
  stdio: "inherit",
});
const cssCode = await readFile(unhashedCss, "utf8");
const cssFile = `app.${contentHash(cssCode)}.css`;
await writeFile(join(assetsDir, cssFile), cssCode);
await rm(unhashedCss);

let html = await readFile(join(srcDir, "index.html"), "utf8");
for (const [marker, tag] of [
  ["<!-- @app-stylesheet -->", `<link rel="stylesheet" href="assets/${cssFile}" />`],
  ["<!-- @app-script -->", `<script type="module" src="assets/${jsFile}"></script>`],
]) {
  if (!html.includes(marker)) throw new Error(`missing marker in index.html: ${marker}`);
  html = html.replace(marker, tag);
}
await writeFile(join(outDir, "index.html"), html);

console.log(`dashboard built -> ${outDir}`);
console.log(`  ${jsFile} ${(jsCode.length / 1024).toFixed(1)} KB`);
console.log(`  ${cssFile} ${(cssCode.length / 1024).toFixed(1)} KB`);
