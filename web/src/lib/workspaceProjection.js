export function normalizedIdentifier(value) {
  return String(value ?? "").replaceAll("-", "").toLowerCase();
}

// DomainOperation payloads are sparse. Preserve unknown top-level fields and
// merge known dictionary buckets one level deep so older/newer clients can
// project the same fixture without dropping fields they do not understand.
export function mergeProjectionPayload(basePayload, deltaPayload) {
  if (!basePayload || typeof basePayload !== "object") return deltaPayload ?? {};
  if (!deltaPayload || typeof deltaPayload !== "object") return basePayload;

  const merged = { ...basePayload };
  for (const [key, value] of Object.entries(deltaPayload)) {
    const baseValue = basePayload[key];
    if (
      baseValue && typeof baseValue === "object" && !Array.isArray(baseValue) &&
      value && typeof value === "object" && !Array.isArray(value)
    ) {
      merged[key] = { ...baseValue, ...value };
    } else {
      merged[key] = value;
    }
  }
  return merged;
}

export function countByNormalizedIdentifier(items, selectIdentifier) {
  const counts = new Map();
  for (const item of items) {
    const key = normalizedIdentifier(selectIdentifier(item));
    if (!key) continue;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

export function uniqueByNormalizedIdentifier(items, selectIdentifier) {
  const unique = new Map();
  for (const item of items) {
    const key = normalizedIdentifier(selectIdentifier(item));
    if (!unique.has(key)) unique.set(key, item);
  }
  return [...unique.values()];
}
