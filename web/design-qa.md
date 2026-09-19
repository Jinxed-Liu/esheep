# eSheep+ Web — 晴空玻璃实现验收

Date: 2026-09-17. Scope: approved visual design implemented in the existing React application; local component and interaction acceptance. This report supersedes the old rail-based home visual report. Its original text and previous analytics evidence remain in the backup below and existing design assets.

## Evidence

- Approved target: `design-qa-assets/skyglass-approved.png` (1586 × 992).
- Browser implementation: `design-qa-assets/skyglass-desktop.png` (1586 × 992).
- Side-by-side source + implementation: `design-qa-assets/skyglass-comparison.png`.
- Focused comparisons: `skyglass-actions-comparison.png`, `skyglass-header-comparison.png` in the same directory.
- Mobile: `skyglass-mobile.png`, `skyglass-mobile-activity.png` (390 × 844).
- Empty data: `skyglass-empty.png` (390 × 844); counts render as zero and recent activity shows the empty-state message.
- Local URL: http://127.0.0.1:5178/design-qa-assets/skyglass-review.html
- Fixture harness mounts actual application components. It imports no cloud client and uses a no-op save; the visible footer identifies example data. Actual authenticated application entry remains `/`.

## Source comparison and corrections

The source and browser capture were reviewed together at the same canvas size, followed by focused header/actions crops.

| Area | Result |
| --- | --- |
| Composition | Horizontal capsule navigation, open overview, 2.08:1 production/actions split and full-width activity match the approved hierarchy. No desktop sidebar. |
| Main action | 新建记录 sits inside 今日操作 beside its title. It opens the existing canonical record selector. |
| Typography | Green/ink hero title, large numerals, medium production titles and quiet descriptions retain the source hierarchy. System Chinese font rendering differs slightly from the generated source. |
| Spacing | Main panels begin at y=390 and recent activity at y=732 on the 1586 × 992 canvas. Activity was compacted after comparison. |
| Color and material | Pale sky/mint/gold background, translucent white panels, color-coded icons, glossy green CTA and highlighted green title retained. Final pass strengthened icon gradients and button highlights. |
| Brand and icons | Brand comes from the exact user-supplied Icon Composer document. Sheep tile is generated in the selected style. Standard feature glyphs use existing Phosphor icons; their silhouettes are intentionally not pixel-identical to generated artwork. |
| Content | Real app reads existing metrics/events; no invented day-over-day comparisons. Current farm-local date replaces the mock date. Historical records show dates as well as time. Alerts and TMR sections appear when real data exists. |
| Responsive | Tested widths 320, 390, 768, 1024, 1280, 1586; no page-level horizontal overflow. Mobile uses stacked content and a five-destination bottom bar with reserved page space. |

Fixed during review: initially undersized sheep tile; excessive activity height; mobile bottom-navigation shrink; mobile farm/account popovers positioned below the viewport by legacy CSS. Rechecked farm switching after the menu fix.

P0: none. P1: none. P2: none outstanding in the tested scope. P3: standard glyph silhouettes and exact light/shadow rendering differ from the generated mock; they preserve meaning and layout and are not pixel-perfect reproductions.

## Functional acceptance

- All five primary destinations render: 首页、洞察、录入、投喂、搜索.
- New-record selector exposes 28 canonical choices; weight/transfer/feed quick actions open corresponding existing forms. Mobile selector opens correctly. No business form was submitted.
- Sheep archive opens the actual Flock page; searching D034 returns the expected fixture. Recent D021 entry opens actual event detail. Unified search D021 returns the matching sheep.
- Farm picker switches to the second fixture farm and back; account menu opens settings/assistant entries; Escape dismisses menus.
- Empty metrics preserve zero; the activity empty-state copy is visible.
- A development-only harness HMR duplicate-root warning was addressed with root disposal. Final fresh browser load plus new-record open/close had zero console errors/warnings.

## Automated verification

- `npm run build`: passed; production client and server artifacts generated.
- `npm test`: 95/95 passed.
- `npm run test:sites`: 6/6 passed (subset also present in the full suite).
- `git diff --check`: passed.
- Production artifact check: `dist/client/index.html`, `dist/server/index.js`, `dist/.openai/hosting.json` exist.
- Production JS/HTML scan found no `review-weight`, `skyglass-review`, or second fixture-farm string; review entry is not a build input.

## Boundaries and recovery

This validates local layout and component behavior. It does not claim live cloud write acceptance, signed-in farm end-to-end regression, deployment, or physical-device acceptance. Existing cloud/projection code and other pre-existing working-tree changes were preserved.

Before-edit backup: `backups/web-skyglass-20260917-000344/`, including touched-file originals, manifest, and the pre-existing web diff. User icon source was not modified.

final result: passed
