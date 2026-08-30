import { Readable } from "node:stream";

export async function handleNodeRequest(request, response, fetchHandler) {
  const host = request.headers.host ?? "127.0.0.1";
  const url = new URL(request.url ?? "/", `http://${host}`);
  const body = ["GET", "HEAD"].includes(request.method ?? "GET") ? undefined : Readable.toWeb(request);
  const abortController = new AbortController();
  request.once("aborted", () => abortController.abort());
  response.once("close", () => {
    if (!response.writableEnded) abortController.abort();
  });
  const webRequest = new Request(url, {
    method: request.method,
    headers: request.headers,
    body,
    ...(body ? { duplex: "half" } : {}),
    signal: abortController.signal,
  });
  const webResponse = await fetchHandler(webRequest);
  if (!webResponse) return false;
  response.statusCode = webResponse.status;
  for (const [name, value] of webResponse.headers) response.setHeader(name, value);
  if (!webResponse.body || request.method === "HEAD") {
    response.end();
    return true;
  }
  const reader = webResponse.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!response.write(Buffer.from(value))) await new Promise((resolve) => response.once("drain", resolve));
    }
    response.end();
  } catch (error) {
    response.destroy(error);
  }
  return true;
}
