import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Check the shipped entry stylesheet, not preserved assets from older releases.
// The home overview must stay open in every weather and content theme.
export function verifyHomeOverviewStyle(clientRoot) {
  const html = readFileSync(path.join(clientRoot, "index.html"), "utf8");
  const stylesheets = [...html.matchAll(/<link\b[^>]*rel="stylesheet"[^>]*href="([^"]+)"[^>]*>/g)];
  if (!stylesheets.length) throw new Error("Home overview check: no entry stylesheet found.");
  let overviewFound = false;
  for (const [, href] of stylesheets) {
    const css = readFileSync(path.join(clientRoot, href.replace(/^\//, "")), "utf8");
    for (const [, selectors, body] of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      if (!selectors.split(",").some(selector => /\.sky-overview\s*$/.test(selector))) continue;
      overviewFound = true;
      for (const declaration of body.split(";")) {
        const separator = declaration.indexOf(":");
        if (separator < 0) continue;
        const property = declaration.slice(0, separator).trim();
        const value = declaration.slice(separator + 1).replace(/\s*!important\s*$/, "").trim();
        if (/^(background(?:-image|-color)?|box-shadow|backdrop-filter|border(?:-color|-style|-width)?)$/.test(property)
          && !/^(none|transparent|0(?:px)?)$/.test(value)) {
          throw new Error(`Home overview frame returned in ${href}: ${selectors.trim()} { ${declaration.trim()} }. Deployment stopped.`);
        }
      }
    }
  }
  if (!overviewFound) throw new Error("Home overview check: overview layout missing from entry CSS.");
  console.log("Home overview check passed: no themed outer frame in entry CSS.");
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  verifyHomeOverviewStyle(path.resolve(process.argv[2] ?? "dist/client"));
}
