# Prototype Instructions

Run the local server yourself and open the preview in the browser available to this environment. Do not give the user server-start instructions when you can run it.

Before making substantial visual changes, use the Product Design plugin's `get-context` skill when the visual source is unclear or no longer matches the current goal. When the user gives durable prototype-specific design feedback, preferences, or decisions, record them in `AGENTS.md`.

When implementing from a selected generated mock, treat that image as the source of truth for layout, component anatomy, density, spacing, color, typography, visible content, and hierarchy.

Build app UI in `src/`. Keep `.openai/hosting.json`, `worker/index.js`, `scripts/prepare-sites-build.mjs`, and `tests/sites-worker.test.mjs` intact so the same local prototype can be handed to Sites. Before a Sites handoff, run `npm run build` and `npm run test:sites`; the build must leave `dist/client/index.html`, `dist/server/index.js`, and `dist/.openai/hosting.json`.

## Durable eSheep+ Web decisions

- The public product, website, Web App, domain, and Cloudflare resources are named eSheep+ / eSheepPlus / esheepplus. `eSheepNext` is only the current development-era repository and code-project name; do not expose it as the product brand.

- The user rejected the previous Web product because it was visually dated and its feature hierarchy did not match the iOS App. Do not treat this as a cosmetic-only restyle.
- The Web top-level navigation must mirror `FarmWorkspaceView`: `首页 / 洞察 / 录入 / 投喂 / 搜索`. Sheep and pens open from Home; TMR stays inside Feeding; health/reproduction, production batches, and event history stay inside Records; account and farm settings stay behind the avatar.
- The selected redesign source of truth is `design-qa-assets/home-redesign-option-1.png` at 1487 × 1058. Preserve its slim left rail, quiet top bar, open main work area, narrow action column, typography hierarchy, spacing, and restrained blue/white visual system.
- Cloud projection and production-write truth remain product requirements. Never label a browser-only draft, preview fixture, or unavailable App capability as synced or submitted.
- The Records page must expose Excel batch entry with the App's canonical template contract; Web builds generate the downloadable workbook from `FarmExcelImportService` instead of maintaining an independent schema.
- Event history must lead with the sheep ear tag and a concrete business event name/value. Raw entity IDs are diagnostic fallbacks only and must not replace an available ear tag; `CareCommand` tuple payloads such as purpose changes require explicit decoding.
- Web registration creates a free account only. It must never offer or imply cloud-farm creation; an authenticated account without a farm sees only the invite-redemption state. Creating a cloud farm is entitlement-gated server-side, while accepting an invitation remains available to free accounts.
