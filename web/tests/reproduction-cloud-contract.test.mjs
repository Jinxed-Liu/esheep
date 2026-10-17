import test from "node:test";
import assert from "node:assert/strict";
import { validateReproductionContract, reproductionContractVersion } from "../../supabase/functions/esheep-cloud-v2-writes/reproduction-contract.mjs";
const id = "00000000-0000-4000-8000-000000000001";
const command = subject => ({payload:{body:{recordReproductionBatch:{_0:{subjects:[subject]}}}}});
test("cloud accepts legacy drafts and validates new association metadata", () => {
  assert.equal(reproductionContractVersion,1);
  assert.doesNotThrow(()=>validateReproductionContract(command({eweID:id})));
  assert.doesNotThrow(()=>validateReproductionContract(command({eweID:id,reproductionCycleID:id,breedingRoundID:id,breedingIntent:"newRound"})));
  assert.throws(()=>validateReproductionContract(command({eweID:id,breedingIntent:"supplement"})),/requires_breeding/);
  assert.throws(()=>validateReproductionContract(command({eweID:id,breedingIntent:"newRound",relatedBreedingRecordID:id})),/cannot_reference/);
  assert.throws(()=>validateReproductionContract(command({eweID:id,reproductionCycleID:"wrong"})),/invalid_reproduction/);
});
