# Account deletion worker

This Edge Function processes the idempotent jobs created by
`request_account_deletion()`. It must never be called from the iOS app.

Production setup:

1. Configure `ACCOUNT_DELETION_WORKER_SECRET` as a generated server secret.
2. Keep `SUPABASE_SERVICE_ROLE_KEY` in Edge Function secrets only.
3. Deploy with JWT verification disabled because the scheduler authenticates
   with the dedicated worker secret.
4. Schedule an HTTPS `POST` every five minutes with
   `Authorization: Bearer <ACCOUNT_DELETION_WORKER_SECRET>`.
5. Alert on failed jobs, twelve attempts, or any job older than 24 hours.

Before production, test the owner-blocked case, idempotent duplicate requests,
membership/device cleanup, preserved anonymized farm history, Auth deletion,
retry backoff and completed status retention. Deployment is blocked until the
Staging evidence is recorded.
