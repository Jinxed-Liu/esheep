# Repository guidance

Use the files relevant to the task. For Web work, follow `web/AGENTS.md`; for farm query semantics, use `eSheepNext/InsightSkills/farm-data-query/SKILL.md` and the executable contract in `FarmDataQuerySkill.swift`. Read release, cloud, or design documents when that work requires them.

- Preserve farm facts, historical records, and the cloud authority boundary. Route business mutations through the existing command and audited cloud pipeline. Do not mask a sync or projection defect with a local cache or duplicate entry.
- Keep local checks proportional to the change. `./tools/verify_local.sh` accepts `static`, `ios`, `web`, `backend`, and `db`; select affected gates. The `db` gate resets a local Supabase instance, so use only a disposable one. Build, tests, cloud deployment, and physical device acceptance are distinct evidence.
- Inspect the current diff before editing shared files. Preserve unrelated worktree changes. For data, release, or broad refactors, keep a recoverable backup. Report what was verified and what still needs external acceptance.
