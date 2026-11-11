import assert from "node:assert/strict";
import test from "node:test";
import { generatedAssetHeaders, staticAssetCacheControl } from "../server/static-asset-cache.mjs";

test("only versioned build output receives immutable browser caching", () => {
  for (const asset of ["/assets/index-BKw6-4qi.js", "/assets/FlockPage-Btz2sTCU.css", "/assets/lzfse-12345678.wasm"]) {
    assert.equal(staticAssetCacheControl(asset), "public, max-age=31536000, immutable");
  }
  for (const asset of ["/", "/index.html", "/assets/esheepplus-icon.png", "/assets/appEventExportContract.json", "/manifest.webmanifest", "/api/cloud/rest/v1/profiles", "/assets/app.js"]) {
    assert.equal(staticAssetCacheControl(asset), "public, max-age=0, must-revalidate");
  }
});

test("Workers headers cover versioned assets without matching private routes or mutable manifests", () => {
  const headers = generatedAssetHeaders(["assets/index-12345678.js", "assets/index-12345678.css", "index.html", "assets/compatibility-manifest.json"]);
  assert.equal(headers, "/assets/index-12345678.css\n  Cache-Control: public, max-age=31536000, immutable\n\n/assets/index-12345678.js\n  Cache-Control: public, max-age=31536000, immutable\n");
});
