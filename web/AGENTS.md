# Prototype Instructions

Run the local server yourself and open the preview in the browser available to this environment. Do not give the user server-start instructions when you can run it.

Before making substantial visual changes, use the Product Design plugin's `get-context` skill when the visual source is unclear or no longer matches the current goal. When the user gives durable prototype-specific design feedback, preferences, or decisions, record them in `AGENTS.md`.

When implementing from a selected generated mock, treat that image as the source of truth for layout, component anatomy, density, spacing, color, typography, visible content, and hierarchy.

Build app UI in `src/`. Keep `.openai/hosting.json`, `worker/index.js`, `scripts/prepare-sites-build.mjs`, and `tests/sites-worker.test.mjs` intact so the same local prototype can be handed to Sites. Before a Sites handoff, run `npm run build` and `npm run test:sites`; the build must leave `dist/client/index.html`, `dist/server/index.js`, and `dist/.openai/hosting.json`.

## Durable eSheep+ Web decisions

- On 2026-09-27 the user selected `design-qa-assets/pasture-approved.png` for implementation. The direction uses a sunny pasture background, two photographic production rows, quiet translucent main sheets, open operation rows with fine dividers, a blue primary action, and the exact App-exported ear-tag logo. Earlier image-generation attempts made the glass too strong or too weak; avoid thick glowing borders, plastic-looking icon tiles, and nested glass cards.

- The public product, website, Web App, domain, and Cloudflare resources are named eSheep+ / eSheepPlus / esheepplus. `eSheepNext` is only the current development-era repository and code-project name; do not expose it as the product brand.

- The user rejected the previous Web product because it was visually dated and its feature hierarchy did not match the iOS App. Do not treat this as a cosmetic-only restyle.
- The Web top-level navigation must mirror `FarmWorkspaceView`: `首页 / 洞察 / 录入 / 投喂 / 搜索`. Sheep and pens open from Home; TMR stays inside Feeding; health/reproduction, production batches, and event history stay inside Records; account and farm settings stay behind the avatar.
- The 2026-09-17 visual target was `design-qa-assets/skyglass-approved.png` at 1586 × 992. The 2026-09-27 pasture concept above supersedes its home visuals while keeping horizontal navigation, a green 今日牧场 title, the two-row production area, a right-hand 今日操作 panel, and the recent-activity feed. Keep 新建记录 inside the 今日操作 header, beside its title.
- Use `public/assets/esheepplus-icon.png`, exported directly from the user-supplied `/Users/jinxliu/Desktop/eSheep+.icon`, for the product logo and favicon. Do not replace it with a generated approximation.
- Desktop has no sidebar. At <=600px the five destinations become a full-width floating bottom navigation. Preserve working farm/account menus and the Codex assistant (under the account menu and Insights).
- Mock figures and day-over-day deltas are design examples only. Home uses `workspace.metrics` and newest `workspace.events`; never fabricate comparisons or display preview fixtures in the authenticated app. `design-qa-assets/skyglass-review.html` is a separate local component harness excluded from production builds.
- Cloud projection and production-write truth remain product requirements. Never label a browser-only draft, preview fixture, or unavailable App capability as synced or submitted.
- The Records page must expose Excel batch entry with the App's canonical template contract; Web builds generate the downloadable workbook from `FarmExcelImportService` instead of maintaining an independent schema.
- Event history must lead with the sheep ear tag and a concrete business event name/value. Raw entity IDs are diagnostic fallbacks only and must not replace an available ear tag; `CareCommand` tuple payloads such as purpose changes require explicit decoding.
- Web registration creates a free account only. It must never offer or imply cloud-farm creation; an authenticated account without a farm sees only the invite-redemption state. Creating a cloud farm is entitlement-gated server-side, while accepting an invitation remains available to free accounts.
