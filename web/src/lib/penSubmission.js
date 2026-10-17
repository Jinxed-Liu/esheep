import { listDrafts, saveDraft } from "./draftStore.js";
import { submitWorkspaceDraft } from "./workspaceSubmission.js";

// A pen form keeps one draft ID for its entire lifetime, including uncertain
// responses. Accepted receipts and a successful projection refresh are separate.
export async function submitPenManagement({ cloud, workspace, record, draftID, assertCurrent, onWorkspace, onDrafts, onProgress = () => {}, noun = "羊舍" }) {
  const accountID = workspace.profile.accountID, farm = workspace.farm;
  assertCurrent();
  const previous = (await listDrafts(accountID, farm.id)).find(item => item.id === draftID);
  assertCurrent();
  const draft = previous?.signed ? previous : await saveDraft(accountID, farm, record, draftID);
  assertCurrent();
  try {
    const { result } = await submitWorkspaceDraft({ cloud, workspace, draft, assertCurrent, onProgress });
    assertCurrent();
    if (result.status !== "accepted") throw new Error(result.status === "conflict"
      ? "云端发现资料冲突，原始回执已保留，请在“录入”中核对。"
      : "云端未接受本次操作，原始回执已保留，请在“录入”中核对。");
    let refreshed = false;
    try {
      onProgress(`云端已接受，正在更新${noun}资料…`);
      const updated = await cloud.loadCloudWorkspace(farm.id);
      assertCurrent();
      if (updated.profile.accountID !== accountID || updated.farm.id !== farm.id) throw new Error("账号或牧场已切换。");
      onWorkspace(updated);
      refreshed = true;
    } catch { assertCurrent(); }
    return { accepted: 1, refreshed };
  } catch (error) {
    const saved = (await listDrafts(accountID, farm.id)).find(item => item.id === draft.id);
    error.signed = Boolean(saved?.signed);
    throw error;
  } finally {
    const drafts = await listDrafts(accountID, farm.id);
    assertCurrent();
    onDrafts(drafts);
  }
}
