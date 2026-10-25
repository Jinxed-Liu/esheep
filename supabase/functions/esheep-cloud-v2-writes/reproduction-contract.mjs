export const reproductionContractVersion = 1;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function reproductionDraft(body, depth = 0) {
  if (!body || typeof body !== "object" || depth > 5) return null;
  if (body.recordReproductionBatch) return body.recordReproductionBatch._0 ?? body.recordReproductionBatch;
  if (body.correctReproduction) return body.correctReproduction.replacement ?? body.correctReproduction._1;
  if (body.recordLambing) return body.recordLambing._0 ?? body.recordLambing;
  if (body.correctLambing) return body.correctLambing.replacement ?? body.correctLambing._1;
  for (const value of Object.values(body)) { const found = reproductionDraft(value, depth + 1); if (found) return found; }
  return null;
}
export function validateReproductionContract(unsigned) {
  const draft = reproductionDraft(unsigned?.payload?.body);
  if (!draft) return;
  for (const subject of draft.subjects ?? [draft]) {
    for (const field of ["reproductionCycleID", "breedingRoundID", "relatedBreedingRecordID"]) {
      if (subject[field] != null && !uuid.test(subject[field])) throw new Error(`invalid_reproduction_${field}`);
    }
    if (subject.breedingIntent != null && !["newRound", "supplement"].includes(subject.breedingIntent)) throw new Error("invalid_breeding_intent");
    if (subject.breedingIntent === "supplement" && !subject.relatedBreedingRecordID) throw new Error("supplement_requires_breeding_reference");
    if (subject.breedingIntent === "newRound" && subject.relatedBreedingRecordID) throw new Error("new_round_cannot_reference_previous_breeding");
  }
}
