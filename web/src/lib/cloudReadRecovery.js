export function isTransientJWTClockError(error) {
  return error?.code === "PGRST303" && /JWT issued at future/i.test(String(error?.message ?? ""));
}

function abortError() {
  const error = new Error("牧场读取已取消。");
  error.name = "AbortError";
  return error;
}

function waitForRetry(delayMs, signal) {
  if (signal?.aborted) return Promise.reject(abortError());
  return new Promise((resolve, reject) => {
    const onAbort = () => {
      clearTimeout(timer);
      reject(abortError());
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, delayMs);
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

export async function loadWithTransientJWTClockRetry(load, { signal, delayMs = 750 } = {}) {
  try {
    return await load();
  } catch (error) {
    if (signal?.aborted) throw abortError();
    if (!isTransientJWTClockError(error)) throw error;
    await waitForRetry(delayMs, signal);
    signal?.throwIfAborted();
    return load();
  }
}

export function cloudAccessErrorMessage(error) {
  if (isTransientJWTClockError(error)) {
    return "云端身份校验暂时异常，已自动重试。请稍后再次读取牧场。";
  }
  return error?.message || "牧场资料读取失败，请重试。";
}
