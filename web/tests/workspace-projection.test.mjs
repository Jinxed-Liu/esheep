import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  countByNormalizedIdentifier,
  mergeProjectionPayload,
  normalizedIdentifier,
  uniqueByNormalizedIdentifier,
} from "../src/lib/workspaceProjection.js";

const fixture = JSON.parse(
  readFileSync(new URL("./fixtures/workspace-projection-v1.json", import.meta.url), "utf8"),
);

test("merges sparse projection payloads without dropping unknown fields", () => {
  assert.deepEqual(
    mergeProjectionPayload(fixture.payloadMerge.base, fixture.payloadMerge.delta),
    fixture.payloadMerge.expected,
  );
});

test("normalizes UUID and legacy identifiers consistently", () => {
  for (const [input, expected] of fixture.identifierPairs) {
    assert.equal(normalizedIdentifier(input), expected);
  }
});

test("counts sheep per pen in one pass and ignores missing pen identifiers", () => {
  const counts = countByNormalizedIdentifier(fixture.sheep, (sheep) => sheep.penID);
  assert.deepEqual(Object.fromEntries(counts), fixture.expectedPenCounts);
});

test("keeps the first projection for duplicate normalized identifiers", () => {
  const recipes = uniqueByNormalizedIdentifier(fixture.recipes, (recipe) => recipe.id);
  assert.deepEqual(recipes.map((recipe) => recipe.name), fixture.expectedRecipeNames);
});
