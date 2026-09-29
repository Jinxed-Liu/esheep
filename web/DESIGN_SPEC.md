# eSheep+ Web — 晴空玻璃

2026-09-27 homepage refresh: the selected pasture concept is `design-qa-assets/pasture-approved.png`. It supersedes the older home visual below. Keep authentic data, actions and navigation while using the new pasture background, photographic production entries, restrained translucent panels, open operation rows and blue New Record action. Continue to use the exact App-exported logo asset.

Earlier target: `design-qa-assets/skyglass-approved.png`, 1586 × 992. Its visual styling was superseded by the 2026-09-27 pasture concept above.

## Layout and visual decisions

- Horizontal product header: original ear-tag icon and blue eSheep+ wordmark; five-item frosted capsule; farm switcher and account menu. No desktop sidebar.
- Primary navigation stays 首页 / 洞察 / 录入 / 投喂 / 搜索. Existing business destinations and route callbacks remain intact. Codex assistant is accessible from the account menu and Insights.
- Main canvas: 3.5% side margins, pale sky/mint/gold atmospheric raster background, maximum 1760px width. Green/ink 今日牧场 title and current farm-local date.
- Three open metrics: sheep, occupied pens, today's feeding. Read existing projections without new statistical definitions.
- 2.08:1 content columns: sheep/pen production entries on left, daily operations on right. 新建记录 sits beside 今日操作, above weight/transfer/feed actions.
- Full-width recent-activity feed opens existing event details. Keep readable object, business label, details and occurrence date; historical events show their date, not just a misleading clock time.
- Existing non-empty operational alerts and TMR summaries remain available below the main feed. Footer links retain access when there are no results.
- <=1150px: navigation wraps into a second header row. <=800px: production and actions stack. <=600px: five destinations become a floating bottom bar; page padding reserves space. Small-screen popovers are pinned below the top header.

## Tokens and assets

- Text `#0c1835`; secondary `#647394`; brand blue `#0b5fe9`; title green `#189952`; CTA green `#20a85b`; separators `#e0e9f4`.
- Typography uses existing SF Pro / PingFang SC system stack. Desktop title up to 68px, metrics up to 52px, production titles 23px, supporting text 14–16px. Mobile title 44px.
- Glass surfaces use restrained borders, translucent fills, inset highlights and shadows; retain the approved color and softness. The user explicitly rejected a flattened, muted reinterpretation.
- `public/assets/esheepplus-icon.png`: native Icon Composer export, iOS Default, design generation 27, 256 points at 2x. Source remains untouched at `/Users/jinxliu/Desktop/eSheep+.icon`.
- `public/assets/skyglass-background.jpg`: ImageGen background based on approved mock, optimized to ~101KB. Master retained in design evidence.
- `public/assets/skyglass-sheep.png`: generated matching sheep-head tile, transparent PNG resized to 256px (~69KB).
- Other UI glyphs use the existing Phosphor library; no new icon dependency or generated full-page raster UI.
- Real CSS/React layout lives in `src/skyglass.css`, `AppHeader.jsx`, and `HomeDashboard.jsx`. Existing feature components retain their behavior.

## Data and acceptance boundaries

- No mock numbers, invented trends, fake weather, or fake sync results in the authenticated app.
- Home renders newest three events from the existing workspace; record dialogs use the existing canonical schema and save callbacks.
- Local review harness `design-qa-assets/skyglass-review.html` mounts the real components with clearly identified fixture data and a no-op save. It imports no cloud client and is not a production build input.
- Validation covers local UI, routing, responsive layouts and existing unit tests. It does not constitute live farm submission, production deployment, or physical-device acceptance.

## Motion — 2026-09-29, second pass

- Motion is more expressive in response to intent: a 460ms spring-like navigation capsule, coordinated icon/copy/arrow feedback, 650ms photographic card zoom and bounded pointer tracking, and a single light sweep on New Record.
- `PageMotion` reveals headings, metrics, production/action rows and feature sections with 22px travel and 560ms ease-out. Initial stagger is capped at 270ms; offscreen content reveals once when scrolled into view. Do not animate farm values or individual table rows.
- Entrances use an IntersectionObserver with cleanup and cancellation. There are no scroll listeners, keyed page remounts, new animation dependencies, or animations on every data update. Pointer tracking uses one cancellable animation frame, no React state updates, and resets on leave.
- Feature entry/feeding controls, record-type choices, form focus, segment selection and validation feedback share the same motion vocabulary. Distinct home action icons respond with a tilt, horizontal exchange, or soft bounce.
- Hover/parallax only run on fine pointers. Touch receives press feedback and viewport reveals. Everything comes to rest; backgrounds and numeric values stay still. Menus/dialogs close immediately.
- Reduced motion disables new CSS animations, pointer tracking and reveals, including cancellation when the preference changes live. Content remains visible without entrance effects.
- Validate desktop/mobile, fast navigation, scrolled-in sections, pointer reset, form state, and reduced motion in the isolated development harness. It contains explicitly labeled fixtures and no cloud writes.
