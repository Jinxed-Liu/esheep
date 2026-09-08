import { buildBusinessCommands } from './businessCommands.js';
import { applyV2Event,rebuildCurrentState } from './cloudV2Projection.js';
import { applyExtendedV2Event } from './cloudV2BusinessReplay.js';
export async function preflightImport(records,workspace) {
 const projection={farmID:workspace.farm.id,models:new Map(Object.entries(structuredClone(workspace.models)).map(([name,rows])=>[name,new Map(rows.map(row=>[row.id,row]))])),seenCommands:new Map(),tailOperations:[],changedSheep:new Set()};
 const results=[];let sequence=0;
 for(const record of records){try{
  const models=Object.fromEntries([...projection.models].map(([model,rows])=>[model,[...rows.values()]]));
  const specs=await buildBusinessCommands(record,{...workspace,models});
  for(const spec of specs){const event={event_sequence:++sequence,event_id:crypto.randomUUID(),command_id:crypto.randomUUID(),source_command_digest:'a'.repeat(64),stream_type:spec.streams[0].type,stream_id:spec.streams[0].id,event_kind:'state_machine',actor_account_id:workspace.profile?.accountID,occurred_at_millis:spec.occurredAt,received_at_millis:Date.now()};const body={command_kind:spec.kind,command_payload:{kind:spec.kind,body:spec.body},affected_streams:spec.streams};
   if(!await applyExtendedV2Event(projection,event,body))applyV2Event(projection,event,body);
  }
  rebuildCurrentState(projection,Date.now());
  results.push({sheet:record.sheet,rowNumber:record.rowNumber,commandCount:specs.length});
 }catch(e){throw new Error(`${record.sheet} 第 ${record.rowNumber??'手工'} 行（${record.importKey??''}）：${e.message}`);}}
 return results;
}
