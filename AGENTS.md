# Repository guidance

Use the files relevant to the task. For Web work, follow `web/AGENTS.md`; for farm query semantics, use `eSheepNext/InsightSkills/farm-data-query/SKILL.md` and the executable contract in `FarmDataQuerySkill.swift`. Read release, cloud, or design documents when that work requires them.

- Preserve farm facts, historical records, and the cloud authority boundary. Route business mutations through the existing command and audited cloud pipeline. Do not mask a sync or projection defect with a local cache or duplicate entry.
- Keep local checks proportional to the change. `./tools/verify_local.sh` accepts `static`, `ios`, `web`, `backend`, and `db`; select affected gates. The `db` gate resets a local Supabase instance, so use only a disposable one. Build, tests, cloud deployment, and physical device acceptance are distinct evidence.
- For bug fixes, run only failing tests and directly affected checks. Do not schedule full regression or make it a merge/release prerequisite unless the user explicitly requests it. Reuse completed evidence when the relevant code and tests have not changed; report unrun and skipped checks accurately. This is the user's standing preference, not just a rule for the current task.
- Inspect the current diff before editing shared files. Preserve unrelated worktree changes. For data, release, or broad refactors, keep a recoverable backup. Report what was verified and what still needs external acceptance.
- Support iOS 17 while preserving the existing native interface and animations on newer iOS versions. Gate each newer API by its availability and use fallback implementations only on systems that need them.
  Keep newer SDK types out of concrete class storage that older systems can enumerate through Objective-C. Availability on a class does not protect its stored type metadata; use an erased backing store or an availability-gated struct.
- Batch compatibility validation into one reviewable candidate. Keep push-triggered CI off the iOS 17 compatibility branches and focused checks manual; repeated failing runs generate unwanted GitHub email notifications.
