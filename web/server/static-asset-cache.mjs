const immutablePolicy = "public, max-age=31536000, immutable";

// Only content-addressed build output is immutable. Public images, manifests,
// templates and index.html keep revalidation so updates are not hidden.
export function staticAssetCacheControl(pathname) {
  return /^\/assets\/[^/]+-[A-Za-z0-9_-]{8}\.(?:js|css|wasm|woff2?|png|jpe?g|webp|svg)$/.test(pathname)
    ? immutablePolicy
    : "public, max-age=0, must-revalidate";
}

export function generatedAssetHeaders(fileNames) {
  const paths = [...new Set(fileNames.map(name => `/${name}`))]
    .filter(name => staticAssetCacheControl(name) === immutablePolicy).sort();
  // Workers supports at most 100 static header rules. Fail the build rather
  // than silently shipping an incomplete cache policy if the bundle grows.
  if (paths.length > 100) throw new Error("Static asset cache headers exceed the Workers rule limit.");
  return paths.map(name => `${name}\n  Cache-Control: ${immutablePolicy}\n`).join("\n");
}
