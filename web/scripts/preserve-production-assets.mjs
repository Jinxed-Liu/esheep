// Keep the previous production bundles available to already-open web apps.
// Vite's hashed dynamic imports can outlive index.html in Safari web apps.
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const origin = "https://app.esheepplus.com";
const assetRoot = path.resolve("dist/client");
const manifestPath = "/assets/compatibility-manifest.json";
const assetPattern = /(?:\/assets\/|\.\/|assets\/)([A-Za-z0-9][A-Za-z0-9._-]*\.(?:js|css|png|jpe?g|svg|webp|woff2?))/g;

function references(source) {
  return [...source.matchAll(assetPattern)].map((match) => `/assets/${match[1]}`);
}

function localPath(asset) {
  if (!/^\/assets\/[A-Za-z0-9][A-Za-z0-9._-]+$/.test(asset)) {
    throw new Error(`Invalid production asset path: ${asset}`);
  }
  return path.join(assetRoot, asset);
}

async function remoteAsset(asset) {
  const response = await fetch(new URL(asset, origin), { cache: "no-store" });
  const type = response.headers.get("content-type") ?? "";
  const expected = asset.endsWith(".js") ? /javascript/ :
    asset.endsWith(".css") ? /text\/css/ : /image\/|font\/|application\/font/;
  if (!response.ok || !expected.test(type)) {
    throw new Error(`Production asset unavailable: ${asset} (${response.status}, ${type})`);
  }
  return Buffer.from(await response.arrayBuffer());
}

const page = await fetch(origin, { cache: "no-store" });
if (!page.ok || !(page.headers.get("content-type") ?? "").includes("text/html")) {
  throw new Error("Cannot inspect the current production page; deployment stopped.");
}

let priorGenerations = [];
const priorResponse = await fetch(new URL(manifestPath, origin), { cache: "no-store" });
if (priorResponse.ok && (priorResponse.headers.get("content-type") ?? "").includes("application/json")) {
  const prior = await priorResponse.json();
  if (Array.isArray(prior.generations)) priorGenerations = prior.generations.slice(0, 2);
}

const currentAssets = new Set();
const pending = new Set(references(await page.text()));
const seen = new Set();
let copied = 0;
while (pending.size) {
  const batch = [...pending];
  pending.clear();
  await Promise.all(batch.map(async (asset) => {
    if (seen.has(asset)) return;
    seen.add(asset);
    currentAssets.add(asset);
    const target = localPath(asset);
    let bytes;
    try {
      bytes = await readFile(target);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      bytes = await remoteAsset(asset);
      await mkdir(path.dirname(target), { recursive: true });
      await writeFile(target, bytes);
      copied += 1;
    }
    if (asset.endsWith(".js") || asset.endsWith(".css")) {
      for (const reference of references(bytes.toString("utf8"))) {
        if (!seen.has(reference)) pending.add(reference);
      }
    }
  }));
}

for (const asset of new Set(priorGenerations.flat())) {
  const target = localPath(asset);
  try {
    await readFile(target);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    const bytes = await remoteAsset(asset);
    await writeFile(target, bytes);
    copied += 1;
  }
}

const manifest = {
  generations: [[...currentAssets].sort(), ...priorGenerations].slice(0, 2),
};
await writeFile(localPath(manifestPath), JSON.stringify(manifest));
console.log(`Preserved ${currentAssets.size} current production assets (${copied} copied), plus ${priorGenerations.length} earlier generations.`);
