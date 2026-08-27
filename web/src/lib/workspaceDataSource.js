const allSections = ["overview", "records", "herd", "tmr", "insight"];

const intentSections = {
  overview: ["overview", "records"],
  records: ["overview", "records"],
  herd: ["overview", "records", "herd"],
  tmr: ["overview", "records", "tmr"],
  insight: ["overview", "records", "insight"],
};

const pageIntents = {
  home: "overview",
  flock: "herd",
  entry: "records",
  events: "records",
  feeding: "tmr",
  tmr: "tmr",
  insights: "insight",
  settings: "overview",
};

export function normalizeWorkspaceSections(sections) {
  if (!Array.isArray(sections) || sections.length === 0) return [...allSections];
  const requested = new Set(["overview", "records"]);
  for (const section of sections) {
    if (allSections.includes(section)) requested.add(section);
  }
  return allSections.filter((section) => requested.has(section));
}

export function workspaceSectionsForIntent(intent) {
  return [...(intentSections[intent] ?? intentSections.overview)];
}

export function workspaceSectionsForPage(page) {
  return workspaceSectionsForIntent(pageIntents[page] ?? "overview");
}

export function workspaceEntityTypesForSections(sections) {
  const requested = new Set(normalizeWorkspaceSections(sections));
  const entityTypes = ["farm", "pen", "sheep", "feed", "transfer", "removal"];
  if (requested.has("herd") || requested.has("insight")) {
    entityTypes.push("weight");
  }
  if (requested.has("tmr")) {
    entityTypes.push("feedIngredient", "tmrFormula", "tmrFeedingPlan");
  }
  return entityTypes;
}

export function workspaceHasSections(workspace, requiredSections) {
  if (!workspace || workspace.mode !== "cloud") return false;
  const loaded = new Set(workspace.loadedSections ?? []);
  return normalizeWorkspaceSections(requiredSections).every((section) => loaded.has(section));
}

function abortError(message = "工作区请求已被更新的上下文替代。") {
  const error = new Error(message);
  error.name = "AbortError";
  return error;
}

function contextChangedError(message) {
  const error = new Error(message);
  error.name = "WorkspaceContextChangedError";
  return error;
}

function normalizedFarmID(value) {
  return String(value ?? "").trim().toLowerCase();
}

function workspaceCacheKey(workspace) {
  const farm = workspace?.farm;
  if (!farm?.id || farm.generation == null || farm.revision == null) return null;
  return [
    normalizedFarmID(farm.id),
    String(farm.generation),
    String(farm.revision),
  ].join(":");
}

export class WorkspaceDataSource {
  constructor({ loadWorkspace }) {
    if (typeof loadWorkspace !== "function") {
      throw new TypeError("WorkspaceDataSource requires loadWorkspace.");
    }
    this.loadWorkspace = loadWorkspace;
    this.requestGeneration = 0;
    this.activeRequest = null;
    this.cache = new Map();
  }

  loadOverview(farmID, options) {
    return this.loadIntent("overview", farmID, options);
  }

  loadHerd(farmID, options) {
    return this.loadIntent("herd", farmID, options);
  }

  loadRecords(farmID, options) {
    return this.loadIntent("records", farmID, options);
  }

  loadTMR(farmID, options) {
    return this.loadIntent("tmr", farmID, options);
  }

  loadInsight(farmID, options) {
    return this.loadIntent("insight", farmID, options);
  }

  loadForPage(page, farmID, options) {
    return this.loadSections(workspaceSectionsForPage(page), farmID, options);
  }

  loadIntent(intent, farmID, options) {
    return this.loadSections(workspaceSectionsForIntent(intent), farmID, options);
  }

  loadSections(requiredSections, farmID, options = {}) {
    const currentWorkspace = options.currentWorkspace;
    const requestedFarmID = farmID || currentWorkspace?.farm?.id;
    const sameFarm = Boolean(currentWorkspace?.farm?.id) &&
      normalizedFarmID(currentWorkspace.farm.id) === normalizedFarmID(requestedFarmID);
    const combinedSections = normalizeWorkspaceSections([
      ...(sameFarm ? currentWorkspace?.loadedSections ?? [] : []),
      ...requiredSections,
    ]);

    if (!options.bypassCache && sameFarm && workspaceHasSections(currentWorkspace, combinedSections)) {
      this.remember(currentWorkspace);
      return Promise.resolve(currentWorkspace);
    }

    const currentKey = sameFarm ? workspaceCacheKey(currentWorkspace) : null;
    const cached = currentKey ? this.cache.get(currentKey) : null;
    if (!options.bypassCache && workspaceHasSections(cached, combinedSections)) {
      return Promise.resolve(cached);
    }

    const expectedAuthorityGeneration = sameFarm
      ? currentWorkspace?.farm?.generation ?? null
      : null;
    const requestKey = JSON.stringify({
      farmID: normalizedFarmID(requestedFarmID),
      expectedAuthorityGeneration,
      sections: combinedSections,
    });
    if (this.activeRequest?.key === requestKey) {
      return this.activeRequest.promise;
    }

    this.activeRequest?.controller.abort();
    const controller = new AbortController();
    const generation = ++this.requestGeneration;
    let detachExternalAbort = () => {};
    if (options.signal) {
      const forwardAbort = () => controller.abort(options.signal.reason);
      if (options.signal.aborted) {
        forwardAbort();
      } else {
        options.signal.addEventListener("abort", forwardAbort, { once: true });
        detachExternalAbort = () => options.signal.removeEventListener("abort", forwardAbort);
      }
    }

    const promise = (async () => {
      try {
        controller.signal.throwIfAborted();
        const workspace = await this.loadWorkspace(requestedFarmID, {
          signal: controller.signal,
          sections: combinedSections,
          requestGeneration: generation,
        });
        if (controller.signal.aborted || this.requestGeneration !== generation) {
          throw abortError();
        }
        if (requestedFarmID &&
            normalizedFarmID(workspace?.farm?.id) !== normalizedFarmID(requestedFarmID)) {
          throw contextChangedError("工作区响应不属于当前牧场，请重新装载。");
        }
        if (expectedAuthorityGeneration != null &&
            workspace?.farm?.generation !== expectedAuthorityGeneration) {
          throw contextChangedError("牧场 authority generation 已变化，请重新装载。");
        }
        this.remember(workspace);
        return workspace;
      } catch (error) {
        if (controller.signal.aborted && error?.name !== "AbortError") {
          throw abortError();
        }
        throw error;
      } finally {
        detachExternalAbort();
        if (this.activeRequest?.generation === generation) {
          this.activeRequest = null;
        }
      }
    })();

    this.activeRequest = { key: requestKey, generation, controller, promise };
    return promise;
  }

  remember(workspace) {
    const key = workspaceCacheKey(workspace);
    if (!key) return;
    this.cache.set(key, workspace);
    const farmPrefix = `${normalizedFarmID(workspace.farm.id)}:`;
    for (const cachedKey of this.cache.keys()) {
      if (cachedKey.startsWith(farmPrefix) && cachedKey !== key) {
        this.cache.delete(cachedKey);
      }
    }
  }

  invalidate({ farmID } = {}) {
    this.activeRequest?.controller.abort();
    this.activeRequest = null;
    this.requestGeneration += 1;
    if (!farmID) {
      this.cache.clear();
      return;
    }
    const prefix = `${normalizedFarmID(farmID)}:`;
    for (const key of this.cache.keys()) {
      if (key.startsWith(prefix)) this.cache.delete(key);
    }
  }
}
