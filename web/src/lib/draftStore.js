// One IndexedDB record per authenticated account. Keys and unsubmitted facts
// never cross account boundaries; mutations commit before any network request.
const databaseName = "esheep-web-production-v1";
const requestValue = (request) => new Promise((resolve, reject) => {
  request.onsuccess = () => resolve(request.result);
  request.onerror = () => reject(request.error);
});

async function openDatabase() {
  if (!globalThis.indexedDB) throw new Error("浏览器不支持可靠草稿存储，请更换浏览器后再录入。");
  const request = indexedDB.open(databaseName, 1);
  request.onupgradeneeded = () => request.result.createObjectStore("accounts");
  return requestValue(request);
}

export async function updateAccountStore(accountID, transform) {
  if (!accountID) throw new Error("请先登录再保存草稿。");
  const db = await openDatabase();
  try {
    return await new Promise((resolve, reject) => {
      const tx = db.transaction("accounts", "readwrite");
      const store = tx.objectStore("accounts");
      let result;
      const request = store.get(accountID.toLowerCase());
      request.onsuccess = () => {
        try {
          const state = request.result ?? { drafts: [], device: null, sequence: 0 };
          result = transform(state);
          if (result?.then) throw new Error("草稿事务不能包含异步操作。");
          store.put(state, accountID.toLowerCase());
        } catch (error) { tx.abort(); reject(error); }
      };
      tx.oncomplete = () => resolve(result);
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error ?? new Error("草稿保存失败；请勿关闭页面。"));
    });
  } finally { db.close(); }
}

export async function listDrafts(accountID, farmID) {
  return updateAccountStore(accountID, (state) => state.drafts
    .filter((draft) => draft.farmID === farmID.toLowerCase()).sort((a, b) => b.updatedAt - a.updatedAt));
}

export async function saveDraft(accountID, farm, record, draftID) {
  return updateAccountStore(accountID, (state) => {
    const existing = draftID && state.drafts.find((draft) => draft.id === draftID);
    if (existing && (existing.farmID !== farm.id.toLowerCase() || existing.signed)) {
      throw new Error("已经生成提交请求的记录不能改写；请保留原始回执并另建更正记录。");
    }
    const draft = { ...existing, id: existing?.id ?? crypto.randomUUID(), farmID: farm.id.toLowerCase(),
      generation: farm.generation, record, status: "draft", createdAt: existing?.createdAt ?? Date.now(), updatedAt: Date.now() };
    state.drafts = state.drafts.filter((item) => item.id !== draft.id).concat(draft);
    return draft;
  });
}

export async function patchDraft(accountID, draftID, patch) {
  return updateAccountStore(accountID, (state) => {
    const draft = state.drafts.find((item) => item.id === draftID);
    if (!draft) throw new Error("未找到保存在此浏览器的草稿。");
    Object.assign(draft, patch, { updatedAt: Date.now() });
    return draft;
  });
}

export async function discardDraft(accountID, draftID) {
  return updateAccountStore(accountID, (state) => {
    const draft = state.drafts.find((item) => item.id === draftID);
    if (draft?.signed) throw new Error("已提交或结果待核对的记录必须保留，不能删除原始请求。");
    if (draft) { draft.status = "discarded"; draft.updatedAt = Date.now(); }
  });
}

export async function browserIdentity(accountID) {
  let device = await updateAccountStore(accountID, (state) => state.device);
  if (device) return device;
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"]);
  const candidate = { id: crypto.randomUUID(), privateKey: keys.privateKey,
    publicKeyJWK: await crypto.subtle.exportKey("jwk", keys.publicKey) };
  return updateAccountStore(accountID, (state) => { state.device ??= candidate; return state.device; });
}

export async function reserveSequences(accountID, count, floor = 0) {
  return updateAccountStore(accountID, (state) => {
    const first = Math.max(state.sequence, floor) + 1;
    if (!Number.isSafeInteger(first + count - 1) || count < 1) throw new Error("设备顺序号无效。");
    state.sequence = first + count - 1;
    return first;
  });
}
