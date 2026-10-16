import { submitDraft } from "./cloudV2Writes.js";
import { buildBusinessCommands } from "./businessCommands.js";

// The signed write path checks the current cloud head before building commands.
// Re-read the farm only when that check proves the displayed workspace is stale.
export async function submitWorkspaceDraft({ cloud, workspace, draft, assertCurrent = () => {}, onProgress = () => {} }) {
  let current = workspace;
  for (let attempt = 0; attempt < 2; attempt++) {
    assertCurrent();
    try {
      const result = await submitDraft(cloud.supabase, workspace.profile.accountID, current.farm, draft,
        () => buildBusinessCommands({ ...draft.record, id: draft.id }, current),
        { assertCurrent, onProgress, expectedUserID: workspace.profile.userID });
      assertCurrent();
      return { result, workspace: current };
    } catch (error) {
      assertCurrent();
      if (error.code !== "CLOUD_WORKSPACE_STALE" || attempt !== 0) throw error;
      onProgress("发现新的云端记录，正在同步后核对…");
      current = await cloud.loadCloudWorkspace(workspace.farm.id, { onProgress });
      assertCurrent();
      if (current.profile.accountID !== workspace.profile.accountID || current.profile.userID !== workspace.profile.userID ||
          current.farm.id !== workspace.farm.id || current.farm.generation !== workspace.farm.generation) {
        throw new Error("账号或牧场版本已切换，请重新打开当前牧场。");
      }
    }
  }
}
