import assert from "node:assert/strict";
import test from "node:test";
import {
  WorkspaceDataSource,
  normalizeWorkspaceSections,
  workspaceEntityTypesForSections,
  workspaceHasSections,
  workspaceSectionsForPage,
} from "../src/lib/workspaceDataSource.js";

function cloudWorkspace({
  farmID = "farm-a",
  generation = 3,
  revision = 17,
  loadedSections = ["overview", "records"],
} = {}) {
  return {
    mode: "cloud",
    loadedSections,
    farm: { id: farmID, generation, revision },
  };
}

test("plans overview and route entity reads without eager TMR or weight data", () => {
  assert.deepEqual(
    normalizeWorkspaceSections(["overview"]),
    ["overview", "records"],
  );
  assert.deepEqual(
    workspaceEntityTypesForSections(["overview"]),
    ["farm", "pen", "sheep", "feed", "transfer", "removal"],
  );
  assert.deepEqual(
    workspaceEntityTypesForSections(workspaceSectionsForPage("flock")),
    ["farm", "pen", "sheep", "feed", "transfer", "removal", "weight"],
  );
  assert.deepEqual(
    workspaceEntityTypesForSections(workspaceSectionsForPage("tmr")),
    [
      "farm",
      "pen",
      "sheep",
      "feed",
      "transfer",
      "removal",
      "feedIngredient",
      "tmrFormula",
      "tmrFeedingPlan",
    ],
  );
});

test("reuses a section-complete workspace and accumulates route coverage", async () => {
  const calls = [];
  const source = new WorkspaceDataSource({
    loadWorkspace: async (farmID, options) => {
      calls.push({ farmID, sections: options.sections });
      return cloudWorkspace({ farmID, loadedSections: options.sections });
    },
  });
  const overview = cloudWorkspace();

  const records = await source.loadRecords("farm-a", { currentWorkspace: overview });
  assert.equal(records, overview);
  assert.equal(calls.length, 0);

  const tmr = await source.loadTMR("farm-a", { currentWorkspace: overview });
  assert.deepEqual(calls[0].sections, ["overview", "records", "tmr"]);
  assert.ok(workspaceHasSections(tmr, ["tmr"]));

  const herdAndTMR = await source.loadHerd("farm-a", { currentWorkspace: tmr });
  assert.deepEqual(
    calls[1].sections,
    ["overview", "records", "herd", "tmr"],
  );
  assert.ok(workspaceHasSections(herdAndTMR, ["herd", "tmr"]));
});

test("pins an implicit route request to the current farm", async () => {
  const calls = [];
  const source = new WorkspaceDataSource({
    loadWorkspace: async (farmID, options) => {
      calls.push(farmID);
      return cloudWorkspace({ farmID, loadedSections: options.sections });
    },
  });
  const overview = cloudWorkspace();

  const herd = await source.loadHerd(undefined, { currentWorkspace: overview });

  assert.deepEqual(calls, ["farm-a"]);
  assert.equal(herd.farm.id, "farm-a");
});

test("shares one in-flight request for the same farm authority and sections", async () => {
  let finish;
  let callCount = 0;
  const source = new WorkspaceDataSource({
    loadWorkspace: (farmID, options) => {
      callCount += 1;
      return new Promise((resolve) => {
        finish = () => resolve(cloudWorkspace({
          farmID,
          loadedSections: options.sections,
        }));
      });
    },
  });

  const first = source.loadHerd("farm-a");
  const second = source.loadHerd("farm-a");
  assert.equal(first, second);
  assert.equal(callCount, 1);
  finish();
  await Promise.all([first, second]);
});

test("discards a late response after a rapid farm switch even if the loader ignores abort", async () => {
  const pending = new Map();
  const source = new WorkspaceDataSource({
    loadWorkspace: (farmID, options) => new Promise((resolve) => {
      pending.set(farmID, { resolve, sections: options.sections });
    }),
  });

  const oldRequest = source.loadOverview("farm-a");
  const oldRequestRejected = assert.rejects(oldRequest, { name: "AbortError" });
  const currentRequest = source.loadOverview("farm-b");
  pending.get("farm-b").resolve(cloudWorkspace({
    farmID: "farm-b",
    loadedSections: pending.get("farm-b").sections,
  }));
  const current = await currentRequest;
  assert.equal(current.farm.id, "farm-b");

  pending.get("farm-a").resolve(cloudWorkspace({
    farmID: "farm-a",
    loadedSections: pending.get("farm-a").sections,
  }));
  await oldRequestRejected;
});

test("rejects a response from a changed authority generation", async () => {
  const source = new WorkspaceDataSource({
    loadWorkspace: async (farmID, options) => cloudWorkspace({
      farmID,
      generation: 4,
      loadedSections: options.sections,
    }),
  });
  const current = cloudWorkspace({ generation: 3 });

  await assert.rejects(
    source.loadTMR("farm-a", { currentWorkspace: current }),
    { name: "WorkspaceContextChangedError" },
  );
});
