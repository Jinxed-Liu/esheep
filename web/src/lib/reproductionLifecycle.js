import { stableUUID } from "./nativeEventSnapshots.js";

// Compensation mirrors FarmCareCommandHandler. Removing an offspring detail
// never deletes its independent sheep profile or downstream production facts.
export async function compensateOffspring(detail, parent, { projection, put, at, accountID, reason }) {
  const child = projection.models.get("SheepRecord").get(detail.sheepID);
  const weight=projection.models.get("WeightRecord").get(detail.autoBirthWeightRecordID);
  if(weight&&weight.deletedAt==null){weight.deletedAt=at;weight.revision++;detail.autoBirthWeightRevokedByLambing=true;}
  if (!detail.autoCreatedSheep || !child || child.deletedAt != null) return;
  const before = { dam: child.damID, sire: child.sireID, donor: child.semenDonorID };
  if (child.damID === parent.eweID && child.damProvenanceRawValue === "lambing") { child.damID = null; child.damProvenanceRawValue = null; }
  if (child.sireID === parent.sireID && child.sireProvenanceRawValue === "lambing") { child.sireID = null; child.sireProvenanceRawValue = null; }
  if (child.semenDonorID === parent.semenDonorID && child.sireProvenanceRawValue !== "manual") {
    Object.assign(child,{semenDonorID:null,semenDonorNameSnapshot:null,semenDonorRegistrationNumberSnapshot:null,semenDonorBreedSnapshot:null});
  }
  if(before.dam!==child.damID||before.sire!==child.sireID||before.donor!==child.semenDonorID){
    put("PedigreeChangeRecord",{id:await stableUUID(detail.id,`compensate-${detail.revision+1}`),sheepID:child.id,
      beforeDamID:before.dam,afterDamID:child.damID,beforeSireID:before.sire,afterSireID:child.sireID,
      beforeSemenDonorID:before.donor,afterSemenDonorID:child.semenDonorID,
      beforeDamSourceRawValue:before.dam?"lambing":null,afterDamSourceRawValue:child.damProvenanceRawValue,
      beforeSireSourceRawValue:before.sire||before.donor?"lambing":null,afterSireSourceRawValue:child.sireProvenanceRawValue,
      reason,changedByAccountID:accountID,sheepRevision:child.revision+1,occurredAt:at});
    child.revision++;child.updatedAt=at;detail.autoPedigreeRevokedByLambing=true;
  }
}

export async function setLambingRevoked(revoked, record, context) {
  const {projection,put,at}=context;
  record.deletedAt=revoked?at:null;record.revision++;record.updatedAt=at;
  for(const detail of projection.models.get("LambingOffspringRecord").values()){
    if(detail.lambingRecordID!==record.id)continue;
    if(revoked&&detail.deletedAt==null){
      await compensateOffspring(detail,record,context);
      Object.assign(detail,{deletedByLambingRevocation:true,deletedAt:at,updatedAt:at,revision:detail.revision+1});
    }else if(!revoked&&detail.deletedByLambingRevocation){
      Object.assign(detail,{deletedAt:null,updatedAt:at,revision:detail.revision+1});
      const child=projection.models.get("SheepRecord").get(detail.sheepID);
      if(detail.autoCreatedSheep&&child&&detail.autoPedigreeRevokedByLambing){
        if(child.damProvenanceRawValue!=="manual"){child.damID=record.eweID;child.damProvenanceRawValue="lambing";}
        if(child.sireProvenanceRawValue!=="manual")Object.assign(child,{sireID:record.sireID,sireProvenanceRawValue:record.sireID||record.semenDonorID?"lambing":null,
          semenDonorID:record.semenDonorID,semenDonorNameSnapshot:record.semenDonorNameSnapshot,
          semenDonorRegistrationNumberSnapshot:record.semenDonorRegistrationNumberSnapshot,semenDonorBreedSnapshot:record.semenDonorBreedSnapshot});
        child.revision++;child.updatedAt=at;
      }
      if(detail.autoBirthWeightRevokedByLambing){const weight=projection.models.get("WeightRecord").get(detail.autoBirthWeightRecordID);if(weight){weight.deletedAt=null;weight.revision++;}}
      detail.autoPedigreeRevokedByLambing=false;detail.autoBirthWeightRevokedByLambing=false;
    }
  }
  for(const reminder of projection.models.get("CareReminderRecord").values())if(reminder.sheepID===record.eweID&&reminder.kindRawValue==="expectedLambing"&&reminder.deletedAt==null){
    if(revoked&&reminder.statusRawValue==="completed")Object.assign(reminder,{statusRawValue:"pending",completedAt:null,revision:reminder.revision+1});
    if(!revoked)Object.assign(reminder,{statusRawValue:"completed",completedAt:at,revision:reminder.revision+1});
  }
}
