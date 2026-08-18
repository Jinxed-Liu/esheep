import { createClient } from "npm:@supabase/supabase-js@2.112.3";

type DeletionJob = {
  deletion_job_id: string;
  user_id: string;
};

type StorageObject = {
  bucket_id: string;
  object_name: string;
};

const requiredEnvironment = (name: string): string => {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`missing_${name.toLowerCase()}`);
  return value;
};

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });

Deno.serve(async (request) => {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const workerSecret = requiredEnvironment("ACCOUNT_DELETION_WORKER_SECRET");
  const authorization = request.headers.get("authorization") ?? "";
  if (authorization !== `Bearer ${workerSecret}`) {
    return json(401, { error: "worker_authorization_required" });
  }

  const supabase = createClient(
    requiredEnvironment("SUPABASE_URL"),
    requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );

  const { data, error } = await supabase.rpc("claim_account_deletion_jobs", {
    p_limit: 20,
  });
  if (error) return json(500, { error: "claim_failed", detail: error.code });

  const jobs = (data ?? []) as DeletionJob[];
  const results: Array<{ deletion_job_id: string; status: string }> = [];

  for (const job of jobs) {
    try {
      while (true) {
        const { data: orphanedObjects, error: orphanQueryError } = await supabase.rpc(
          "list_account_deletion_orphaned_storage",
          { p_deletion_job_id: job.deletion_job_id },
        );
        if (orphanQueryError) throw orphanQueryError;

        const objects = (orphanedObjects ?? []) as StorageObject[];
        if (objects.length === 0) break;
        const objectsByBucket = new Map<string, string[]>();
        for (const object of objects) {
          const names = objectsByBucket.get(object.bucket_id) ?? [];
          names.push(object.object_name);
          objectsByBucket.set(object.bucket_id, names);
        }
        for (const [bucket, names] of objectsByBucket) {
          const { error: storageError } = await supabase.storage.from(bucket).remove(names);
          if (storageError) throw storageError;
        }
      }

      const { error: prepareError } = await supabase.rpc(
        "prepare_account_deletion_job",
        { p_deletion_job_id: job.deletion_job_id },
      );
      if (prepareError) throw prepareError;

      // Deleting the Auth user cascades through profiles. The migration keeps
      // immutable farm history while nulling personal actor references and
      // removes devices, memberships and personal sync rows.
      const { error: deleteError } = await supabase.auth.admin.deleteUser(
        job.user_id,
        false,
      );
      if (deleteError && deleteError.status !== 404) throw deleteError;

      const { error: completeError } = await supabase.rpc(
        "complete_account_deletion_job",
        { p_deletion_job_id: job.deletion_job_id },
      );
      if (completeError) throw completeError;
      results.push({ deletion_job_id: job.deletion_job_id, status: "completed" });
    } catch (error) {
      const errorCode = error instanceof Error ? error.name : "unknown";
      await supabase.rpc("fail_account_deletion_job", {
        p_deletion_job_id: job.deletion_job_id,
        p_error_code: errorCode,
      });
      results.push({ deletion_job_id: job.deletion_job_id, status: "failed" });
    }
  }

  return json(200, { claimed: jobs.length, results });
});
