const SUPPORTED_KINDS = [
  "available_data",
  "farm_overview",
  "sheep_search",
  "pen_summary",
  "event_search",
  "weight_summary",
  "lamb_summary",
  "reproduction_summary",
  "feed_intake_summary",
];

function text(value) {
  return String(value ?? "").trim();
}

function normalized(value) {
  return text(value).toLocaleLowerCase("zh-CN");
}

function finiteLimit(value, fallback = 20, maximum = 100) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(parsed) ? Math.min(maximum, Math.max(1, parsed)) : fallback;
}

function list(value) {
  if (Array.isArray(value)) return value.map(text).filter(Boolean);
  return text(value).split(",").map((item) => item.trim()).filter(Boolean);
}

function asDate(value) {
  const date = value ? new Date(value) : null;
  return date && !Number.isNaN(date.getTime()) ? date : null;
}

function day(value) {
  const candidate = text(value);
  return /^\d{4}-\d{2}-\d{2}$/.test(candidate) ? candidate : null;
}

function eventAt(event) {
  return asDate(event?.at ?? event?.occurredAt ?? event?.recordedAt);
}

function eventView(event) {
  return {
    id: event.id ?? event.operationID ?? null,
    at: event.at ?? event.occurredAt ?? null,
    type: event.type ?? event.kind ?? event.entityType ?? null,
    title: event.title ?? event.action ?? event.summary ?? null,
    detail: event.detail ?? event.description ?? null,
    actor: event.actor ?? event.actorName ?? null,
    earTag: event.earTag ?? event.sheepEarTag ?? null,
    pen: event.pen ?? event.penName ?? null,
    revision: event.revision ?? null,
  };
}

function compactWeight(result) {
  return {
    cutoff: result.cutoff,
    boundary: result.boundary,
    eligibleSheepCount: result.sheepIDs?.length ?? 0,
    canonicalSampleCount: result.canonicalSampleCount,
    sheepSampleCount: result.sheepSampleCount,
    latestAverageWeight: result.latestAverageWeight,
    latestAverageWeightSampleCount: result.latestAverageWeightSampleCount,
    latestAverageADG: result.latestAverageADG,
    latestAverageADGSampleCount: result.latestAverageADGSampleCount,
    weightTrend: result.weightTrend?.slice(-24) ?? [],
    adgTrend: result.adgTrend?.slice(-24) ?? [],
  };
}

function compactLamb(result) {
  return {
    boundary: result.boundary,
    allLambingCount: result.allLambingCount,
    completeLambingCount: result.completeLambingCount,
    incompleteLambingCount: result.incompleteLambingCount,
    totalBorn: result.totalBorn,
    liveBorn: result.liveBorn,
    deadBorn: result.deadBorn,
    mortalityRate: result.mortalityRate,
    weaningCount: result.weaningCount,
    averageWeaningWeightKg: result.averageWeaningWeightKg,
    weaningWeightSampleCount: result.weaningWeightSampleCount,
    averageWeaningADGKgPerDay: result.averageWeaningADGKgPerDay,
    weaningADGSampleCount: result.weaningADGSampleCount,
    lambMonths: result.lambStats?.months ?? [],
    weaningMonths: result.weaning?.months ?? [],
  };
}

function compactReproduction(result) {
  return {
    filter: result.filter,
    boundary: result.boundary,
    cohortCount: result.cohortCount,
    recordCount: result.recordCount,
    completeLambingCount: result.completeLambingCount,
    incompleteLambingCount: result.incompleteLambingCount,
    overview: result.overview,
    averageLitterSize: result.averageLitterSize,
    litterSampleCount: result.litterSampleCount,
    monthly: result.monthly,
    qualifiedRates: result.qualifiedRates,
    breedRows: result.breedRows,
    intervalPoints: result.intervalPoints?.slice(-24) ?? [],
    postpartumPoints: result.postpartumPoints?.slice(-24) ?? [],
  };
}

function compactFeedPen(pen) {
  return {
    id: pen.id,
    name: pen.name,
    freshKilograms: pen.freshKilograms,
    sheepDays: pen.sheepDays,
    nutrition: pen.nutrition,
    growth: pen.growth,
    evidence: [...(pen.evidence ?? [])],
    conflicts: pen.conflicts ?? [],
    completeIntervalCount: pen.completeIntervalCount,
    incompleteIntervalCount: pen.incompleteIntervalCount,
    dailyTrend: (pen.dailyTrend ?? []).map((point) => ({
      ...point,
      evidence: [...(point.evidence ?? [])],
    })),
  };
}

function envelope(snapshot, kind, filters, rowCount, result, extraCompleteness = {}) {
  const farm = snapshot.farm ?? {};
  return {
    ok: true,
    evidence_kind: "supabase_projection",
    query_id: `${farm.id ?? "unknown"}:${kind}:${snapshot.capturedAt ?? "unknown"}`,
    query_kind: kind,
    source_description: snapshot.source?.description ?? "eSheep+ 只读牧场快照",
    filters_applied: filters,
    as_of: snapshot.capturedAt ?? null,
    time_zone: farm.timeZoneIdentifier ?? "Asia/Shanghai",
    row_count: rowCount,
    completeness: {
      projection: snapshot.projectionCoverage ?? null,
      dataAvailability: snapshot.dataAvailability ?? null,
      ...extraCompleteness,
    },
    result,
  };
}

export function createFarmQueryEngine(analytics) {
  const {
    calculateFeedIntakeAnalytics,
    calculateLambAnalytics,
    calculateReproductionAnalytics,
    calculateWeightAnalytics,
    defaultFeedRange,
    defaultReproductionFilter,
    weightFilterOptions,
  } = analytics;

  return function runFarmQuery(snapshot, request = {}) {
    if (!snapshot || snapshot.schemaVersion !== "esheepnext-farm-assistant/v1" || !snapshot.farm?.id) {
      throw new Error("牧场快照格式无效。");
    }
    const kind = text(request.kind);
    if (!SUPPORTED_KINDS.includes(kind)) {
      throw new Error(`不支持的查询类型：${kind || "（空）"}。可用类型：${SUPPORTED_KINDS.join("、")}`);
    }
    const source = snapshot.analyticsSource ?? {};
    const timeZone = snapshot.farm.timeZoneIdentifier || "Asia/Shanghai";
    const now = asDate(snapshot.capturedAt) ?? new Date();

    if (kind === "available_data") {
      return envelope(snapshot, kind, {}, 1, {
        supportedQueryKinds: SUPPORTED_KINDS,
        dataAvailability: snapshot.dataAvailability ?? {},
        farm: { id: snapshot.farm.id, name: snapshot.farm.name, revision: snapshot.farm.revision },
      });
    }

    if (kind === "farm_overview") {
      return envelope(snapshot, kind, {}, 1, {
        farm: {
          id: snapshot.farm.id,
          name: snapshot.farm.name,
          revision: snapshot.farm.revision,
          role: snapshot.farm.roleName ?? snapshot.farm.role,
        },
        metrics: snapshot.metrics ?? {},
        dataAvailability: snapshot.dataAvailability ?? {},
      });
    }

    if (kind === "sheep_search") {
      const filters = {
        query: text(request.query),
        earTag: text(request.earTag),
        breed: text(request.breed),
        purpose: text(request.purpose),
        sex: text(request.sex),
        penID: text(request.penID),
        limit: finiteLimit(request.limit),
      };
      const queryText = normalized(filters.query);
      const rows = (snapshot.activeSheep ?? []).filter((sheep) => {
        if (filters.earTag && !normalized(sheep.earTag).includes(normalized(filters.earTag))) return false;
        if (filters.breed && normalized(sheep.breed) !== normalized(filters.breed)) return false;
        if (filters.purpose && normalized(sheep.purpose) !== normalized(filters.purpose)) return false;
        if (filters.sex && normalized(sheep.sex) !== normalized(filters.sex)) return false;
        if (filters.penID && normalized(sheep.penID) !== normalized(filters.penID)) return false;
        return !queryText || normalized([sheep.earTag, sheep.breed, sheep.purpose, sheep.pen, sheep.status].join(" ")).includes(queryText);
      });
      return envelope(snapshot, kind, filters, rows.length, {
        totalMatches: rows.length,
        rows: rows.slice(0, filters.limit),
      }, { returnedRows: Math.min(rows.length, filters.limit), resultTruncated: rows.length > filters.limit });
    }

    if (kind === "pen_summary") {
      const filters = { penID: text(request.penID) };
      const rows = (snapshot.pens ?? []).filter((pen) => !filters.penID || normalized(pen.id) === normalized(filters.penID));
      return envelope(snapshot, kind, filters, rows.length, {
        occupiedPenCount: rows.filter((pen) => Number(pen.headCount ?? 0) > 0).length,
        totalHeadCount: rows.reduce((sum, pen) => sum + Number(pen.headCount ?? 0), 0),
        pens: rows.map((pen) => ({ id: pen.id, name: pen.name, headCount: Number(pen.headCount ?? 0) })),
      });
    }

    if (kind === "event_search") {
      const filters = {
        query: text(request.query),
        types: list(request.types),
        startAt: asDate(request.startAt)?.toISOString() ?? null,
        endAt: asDate(request.endAt)?.toISOString() ?? null,
        limit: finiteLimit(request.limit, 30, 100),
      };
      const startAt = asDate(filters.startAt);
      const endAt = asDate(filters.endAt);
      const typeSet = new Set(filters.types.map(normalized));
      const queryText = normalized(filters.query);
      const rows = (snapshot.events ?? []).filter((event) => {
        const at = eventAt(event);
        if (startAt && (!at || at < startAt)) return false;
        if (endAt && (!at || at > endAt)) return false;
        const type = normalized(event.type ?? event.kind ?? event.entityType);
        if (typeSet.size && !typeSet.has(type)) return false;
        return !queryText || normalized(JSON.stringify(event)).includes(queryText);
      });
      return envelope(snapshot, kind, filters, rows.length, {
        totalMatches: rows.length,
        rows: rows.slice(0, filters.limit).map(eventView),
      }, {
        returnedRows: Math.min(rows.length, filters.limit),
        resultTruncated: rows.length > filters.limit || Boolean(snapshot.dataAvailability?.eventsTruncated),
      });
    }

    if (kind === "weight_summary") {
      const options = weightFilterOptions(source, { now, timeZone });
      const scope = ["all", "inHerdOnly", "removedOnly"].includes(request.scope) ? request.scope : "all";
      const filters = {
        scope,
        penID: text(request.penID) || null,
        batchID: text(request.batchID) || null,
        cutoff: asDate(request.cutoff)?.toISOString() ?? options.cutoff,
      };
      const result = calculateWeightAnalytics(source, { ...filters, now, timeZone });
      return envelope(snapshot, kind, filters, result.canonicalSampleCount ?? 0, compactWeight(result));
    }

    if (kind === "lamb_summary") {
      const selectedYear = /^\d{4}$/.test(text(request.selectedYear)) ? text(request.selectedYear) : null;
      const selectedWeaningMonth = /^(全部|0[1-9]|1[0-2])$/.test(text(request.selectedWeaningMonth))
        ? text(request.selectedWeaningMonth)
        : "全部";
      const filters = { selectedYear, selectedWeaningMonth };
      const result = calculateLambAnalytics(source, { ...filters, timeZone });
      return envelope(snapshot, kind, filters, result.allLambingCount ?? 0, compactLamb(result));
    }

    if (kind === "reproduction_summary") {
      const defaults = defaultReproductionFilter({ now, timeZone });
      const filter = {
        ...defaults,
        ...(day(request.startDate) ? { startDate: day(request.startDate) } : {}),
        ...(day(request.endDate) ? { endDate: day(request.endDate) } : {}),
        ...(["all", "pen", "unassigned"].includes(request.penScope) ? { penScope: request.penScope } : {}),
        ...(text(request.penID) ? { penID: text(request.penID) } : {}),
        ...(text(request.breed) ? { breed: text(request.breed) } : {}),
      };
      const result = calculateReproductionAnalytics(source, { filter, now, timeZone });
      return envelope(snapshot, kind, result.filter, result.recordCount ?? 0, compactReproduction(result));
    }

    const defaults = defaultFeedRange({ now, timeZone });
    const filters = {
      startDate: day(request.startDate) ?? defaults.startDate,
      endDateExclusive: day(request.endDateExclusive) ?? defaults.endDateExclusive,
      selectedPenIDs: list(request.selectedPenIDs),
    };
    const result = calculateFeedIntakeAnalytics(source, { ...filters, now, timeZone });
    return envelope(snapshot, kind, filters, result.recordCount ?? 0, {
      start: result.start,
      end: result.end,
      startDate: result.startDate,
      endDateExclusive: result.endDateExclusive,
      inclusiveEndDate: result.inclusiveEndDate,
      overview: result.overview,
      recordCount: result.recordCount,
      todayFeedCount: result.todayFeedCount,
      todayKilograms: result.todayKilograms,
      boundary: result.boundary,
      pens: (result.pens ?? []).map(compactFeedPen),
    });
  };
}

export { SUPPORTED_KINDS };
