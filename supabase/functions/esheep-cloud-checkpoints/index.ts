import { createClient } from "npm:@supabase/supabase-js@2.112.3";
import { withCheckpointCors } from "./cors.mjs";

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), {
  status, headers: { "content-type": "application/json", "cache-control": "no-store", "x-esheep-service-version": "checkpoint-v1-integrated-v1" },
});
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(withCheckpointCors(async (request: Request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });
  try {
    const authorization = request.headers.get("authorization");
    if (!authorization?.startsWith("Bearer ")) return json(401, { error: "authentication_required" });
    const url = Deno.env.get("SUPABASE_URL")!;
    const client = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: identity, error: identityError } = await client.auth.getUser();
    if (identityError || !identity.user) return json(401, { error: "authentication_required" });
    const body = await request.json();
    if (!uuid.test(body.farm_id) || !Number.isSafeInteger(body.farm_generation) || body.farm_generation < 0) {
      return json(400, { error: "invalid_farm" });
    }
    if (body.checkpoint_id != null && !uuid.test(body.checkpoint_id)) return json(400, { error: "invalid_checkpoint" });
    // The caller-scoped RPC authorizes current membership before an admin
    // client is allowed to issue any signed resource ticket.
    const { data, error } = await client.rpc("esheep_cloud_checkpoint_manifest_v1", {
      p_farm_id: body.farm_id, p_farm_generation: body.farm_generation,
      p_checkpoint_id: body.checkpoint_id ?? null,
    });
    if (error) return json(error.code === "42501" ? 403 : 503, { error: "checkpoint_unavailable" });
    if (!data?.manifest && body.checkpoint_id) return json(410, { error: "checkpoint_no_longer_available" });
    if (!data?.manifest) return json(200, { manifest: null, downloads: [], legacy_reason: data?.legacy_reason ?? null });
    const manifest = data.manifest;
    if (manifest.formatVersion !== 1) return json(200, { manifest, downloads: [] });
    const farm = body.farm_id.toLowerCase();
    const checkpoint = String(manifest.checkpointID).toLowerCase();
    if (!uuid.test(checkpoint) || String(manifest.farmID).toLowerCase() !== farm ||
      manifest.farmGeneration !== body.farm_generation || !Array.isArray(manifest.chunks) ||
      manifest.chunks.length > 10000) return json(503, { error: "invalid_checkpoint_manifest" });
    const keys = manifest.chunks.map((chunk: { objectKey: string }, index: number) => {
      const expected = `${farm}/${checkpoint}/${String(index).padStart(5, "0")}.json.gz`;
      if (chunk.objectKey !== expected) throw new Error("invalid_checkpoint_path");
      return expected;
    });
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const downloads: { index: number; url: string }[] = [];
    for (let offset = 0; offset < keys.length; offset += 100) {
      const { data: signed, error: signingError } = await admin.storage
        .from("esheep-cloud-checkpoints").createSignedUrls(keys.slice(offset, offset + 100), 300);
      if (signingError || !signed || signed.some((entry) => !entry.signedUrl || entry.error)) {
        return json(503, { error: "checkpoint_ticket_unavailable" });
      }
      downloads.push(...signed.map((entry, index) => ({ index: offset + index, url: entry.signedUrl })));
    }
    return json(200, { manifest, downloads });
  } catch {
    return json(400, { error: "invalid_checkpoint_request" });
  }
}));
