// Retry only an immutable checkpoint GET. Never replay commands or publish a
// partial response; the caller still verifies both digests and the full model.
function downloadError(message, { retryable = false, refreshTicket = false } = {}) {
  const error = new Error(message);
  error.code = "CLOUD_V2_DOWNLOAD_FAILED";
  error.retryable = retryable;
  error.refreshTicket = refreshTicket;
  return error;
}

function wait(delay, signal) {
  signal?.throwIfAborted();
  return new Promise((resolve, reject) => {
    const abort = () => { clearTimeout(timer); reject(signal.reason); };
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", abort);
      resolve();
    }, delay);
    signal?.addEventListener("abort", abort, { once: true });
  });
}

export async function receiveCheckpointBytes(loadResponse, expected, {
  signal, onBytes = () => {}, onRetry = () => {}, idleTimeoutMs = 30000,
  retryDelayMs = 500, maxAttempts = 3,
} = {}) {
  let refreshTicket = false;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    signal?.throwIfAborted();
    const controller = new AbortController();
    const forwardAbort = () => controller.abort(signal.reason);
    signal?.addEventListener("abort", forwardAbort, { once: true });
    let reader, timer, retry;
    const resetDeadline = () => {
      clearTimeout(timer);
      timer = setTimeout(() => controller.abort(downloadError(
        "资料接收暂时中断，正在重新连接。", { retryable: true },
      )), idleTimeoutMs);
    };
    const cancelReader = () => { void reader?.cancel(controller.signal.reason).catch(() => {}); };
    controller.signal.addEventListener("abort", cancelReader, { once: true });
    try {
      onBytes(0);
      resetDeadline();
      const response = await loadResponse(controller.signal, refreshTicket);
      controller.signal.throwIfAborted();
      if (!response.ok) {
        void response.body?.cancel().catch(() => {});
        // Storage may report an expired signed URL as 400/401/403. Renew it
        // through the authenticated ticket endpoint once, for this checkpoint.
        const expired = [400, 401, 403].includes(response.status) && !refreshTicket;
        throw downloadError("牧场资料下载失败，请重试。", {
          retryable: expired || [408, 429, 500, 502, 503, 504].includes(response.status),
          refreshTicket: expired,
        });
      }
      if (!response.body) throw downloadError("牧场资料未接收完整，请重试。", { retryable: true });
      reader = response.body.getReader();
      const bytes = new Uint8Array(expected);
      let offset = 0;
      while (true) {
        const { value, done } = await reader.read();
        controller.signal.throwIfAborted();
        if (done) break;
        if (offset + value.byteLength > expected) {
          const error = new Error("牧场资料大小核对未通过，请刷新重试。");
          error.code = "CLOUD_V2_INTEGRITY";
          throw error;
        }
        bytes.set(value, offset);
        offset += value.byteLength;
        if (value.byteLength) resetDeadline();
        onBytes(offset);
      }
      if (offset !== expected) throw downloadError("牧场资料未接收完整，请重试。", { retryable: true });
      return bytes;
    } catch (error) {
      signal?.throwIfAborted();
      const failure = controller.signal.aborted ? controller.signal.reason : error;
      const transient = failure?.retryable === true || failure?.code === "CLOUD_NETWORK_FAILED" ||
        failure?.name === "TypeError" || failure?.name === "NetworkError";
      if (!transient || attempt === maxAttempts) throw failure;
      refreshTicket ||= failure.refreshTicket === true;
      retry = true;
    } finally {
      clearTimeout(timer);
      controller.signal.removeEventListener("abort", cancelReader);
      signal?.removeEventListener("abort", forwardAbort);
      // Do not await a stalled source's cancellation handshake before retrying.
      if (reader) {
        void reader.cancel().catch(() => {});
        reader.releaseLock();
      }
    }
    if (retry) {
      onBytes(0);
      onRetry(attempt + 1);
      await wait(retryDelayMs * 2 ** (attempt - 1), signal);
    }
  }
}
