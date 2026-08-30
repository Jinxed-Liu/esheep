const DATABASE_NAME = "esheepnext-private-credentials";
const DATABASE_VERSION = 1;
const STORE_NAME = "mimo-api-keys";
const RECORD_VERSION = 1;

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const memoryCredentials = new Map();
let databasePromise = null;

function normalizedAccountID(value) {
  const accountID = String(value ?? "").trim();
  if (!accountID) throw new Error("当前登录账号无效，无法保存 MiMo API Key。");
  return accountID;
}

export function normalizeMiMoAPIKey(value) {
  const apiKey = String(value ?? "").trim();
  if (!apiKey) throw new Error("请输入你自己的 MiMo API Key。");
  if (apiKey.length < 12 || apiKey.length > 512 || (!apiKey.startsWith("sk-") && !apiKey.startsWith("tp-"))) {
    throw new Error("MiMo API Key 应以 sk- 或 tp- 开头，请检查后重试。");
  }
  return apiKey;
}

export function describeMiMoAPIKey(value) {
  const apiKey = normalizeMiMoAPIKey(value);
  return apiKey.startsWith("tp-") ? "Token Plan" : "Pay-as-you-go";
}

function canPersistCredential() {
  return Boolean(globalThis.indexedDB && globalThis.crypto?.subtle && globalThis.crypto?.getRandomValues);
}

function requestResult(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("浏览器私密存储不可用。"));
  });
}

function transactionComplete(transaction) {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onabort = () => reject(transaction.error ?? new Error("浏览器私密存储事务已中止。"));
    transaction.onerror = () => reject(transaction.error ?? new Error("浏览器私密存储事务失败。"));
  });
}

function openDatabase() {
  if (!canPersistCredential()) return Promise.reject(new Error("浏览器不支持私密凭据存储。"));
  databasePromise ??= new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE_NAME, DATABASE_VERSION);
    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(STORE_NAME)) database.createObjectStore(STORE_NAME, { keyPath: "owner" });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("无法打开浏览器私密存储。"));
    request.onblocked = () => reject(new Error("浏览器私密存储正在被其他页面占用。"));
  });
  return databasePromise;
}

async function ownerKey(accountID) {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(normalizedAccountID(accountID)));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function additionalData(owner) {
  return encoder.encode(`esheepnext-mimo-key:${RECORD_VERSION}:${owner}`);
}

async function readRecord(owner) {
  const database = await openDatabase();
  const transaction = database.transaction(STORE_NAME, "readonly");
  const record = await requestResult(transaction.objectStore(STORE_NAME).get(owner));
  await transactionComplete(transaction);
  return record ?? null;
}

async function writeRecord(record) {
  const database = await openDatabase();
  const transaction = database.transaction(STORE_NAME, "readwrite");
  transaction.objectStore(STORE_NAME).put(record);
  await transactionComplete(transaction);
}

async function deleteRecord(owner) {
  const database = await openDatabase();
  const transaction = database.transaction(STORE_NAME, "readwrite");
  transaction.objectStore(STORE_NAME).delete(owner);
  await transactionComplete(transaction);
}

export async function saveMiMoCredential(accountID, value) {
  const ownerID = normalizedAccountID(accountID);
  const apiKey = normalizeMiMoAPIKey(value);
  const keyType = describeMiMoAPIKey(apiKey);
  const memoryValue = { apiKey, keyType, persistence: "memory" };
  memoryCredentials.set(ownerID, memoryValue);

  if (!canPersistCredential()) return memoryValue;
  try {
    const owner = await ownerKey(ownerID);
    const encryptionKey = await crypto.subtle.generateKey(
      { name: "AES-GCM", length: 256 },
      false,
      ["encrypt", "decrypt"],
    );
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv, additionalData: additionalData(owner) },
      encryptionKey,
      encoder.encode(apiKey),
    );
    await writeRecord({
      owner,
      version: RECORD_VERSION,
      encryptionKey,
      iv,
      ciphertext,
      savedAt: new Date().toISOString(),
    });
    const storedValue = { apiKey, keyType, persistence: "device" };
    memoryCredentials.set(ownerID, storedValue);
    return storedValue;
  } catch {
    return memoryValue;
  }
}

export async function loadMiMoCredential(accountID) {
  const ownerID = normalizedAccountID(accountID);
  const cached = memoryCredentials.get(ownerID);
  if (cached) return cached;
  if (!canPersistCredential()) return null;

  const owner = await ownerKey(ownerID);
  try {
    const record = await readRecord(owner);
    if (!record || record.version !== RECORD_VERSION || !record.encryptionKey || !record.iv || !record.ciphertext) return null;
    const plaintext = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: record.iv, additionalData: additionalData(owner) },
      record.encryptionKey,
      record.ciphertext,
    );
    const apiKey = normalizeMiMoAPIKey(decoder.decode(plaintext));
    const storedValue = { apiKey, keyType: describeMiMoAPIKey(apiKey), persistence: "device" };
    memoryCredentials.set(ownerID, storedValue);
    return storedValue;
  } catch {
    await deleteRecord(owner).catch(() => {});
    return null;
  }
}

export async function removeMiMoCredential(accountID) {
  const ownerID = normalizedAccountID(accountID);
  memoryCredentials.delete(ownerID);
  if (!canPersistCredential()) return;
  const owner = await ownerKey(ownerID);
  await deleteRecord(owner).catch(() => {});
}
