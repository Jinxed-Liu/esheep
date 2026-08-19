# eSheepNext Web — Design QA

## Visual source of truth

- Accepted concept: `design-reference.png`
- Source dimensions: 1487 × 1058 px
- Latest implementation capture: `design-qa-assets/home-1488x1058-final.jpg`
- Latest auth capture: `design-qa-assets/apple-auth-final.png` (settings page with Apple OAuth entry)
- Implementation viewport: 1488 × 1058 CSS px, DPR 1
- Same-scale comparison: `design-qa-assets/home-comparison-final.jpg`
- Responsive evidence: `design-qa-assets/home-mobile-390x844-final.jpg`
- Compared state: default demo workspace, home page, no menus or dialogs open
- Normalization: the 1487 px source was rendered at 1488 px for the side-by-side comparison, a one-pixel horizontal normalization only.

## Comparison method

1. Inspected the accepted concept at original resolution before implementation.
2. Opened the live React app in the Codex in-app browser at 1488 × 1058 and captured the visible viewport.
3. Rendered source and implementation side by side at the same 1488 × 1058 display size.
4. Re-inspected the accepted concept, latest implementation capture, and full same-scale composite at original detail.
5. Exercised the global search, top-level navigation, TMR workspace, feeding workspace, settings/auth surface, and the `称重 → 选择 23081 → 65.2 kg → 确认记录` interaction.

## Inspected surfaces

### Typography

- Date heading scale, weight, letter spacing, and two-line farm identity preserve the concept hierarchy.
- Navigation, alert labels, event table, metrics, and TMR values use the same compact Chinese desktop density.
- No unsupported web font dependency was introduced; the stack uses PingFang/SF/Helvetica system typography.

### Layout and spacing

- The 76 px horizontal app header, cobalt brand block, farm selector, navigation, search, and assistant account area align with the concept.
- The home body preserves the wide left ledger and narrow right operations column.
- Left-card sections, blue timeline rails, three alert rows, five event rows, three metrics, six quick actions, and three TMR meals match the reference anatomy and count.
- The primary above-fold content remains within the exact desktop viewport without horizontal or vertical overflow.
- At 390 × 844, the page has no document-level horizontal overflow; the intentionally wide event table scrolls inside its own container.

### Color, borders, and elevation

- Brand cobalt, pale blue-gray canvas, white cards, neutral borders, red/orange alerts, green feed events, and gray progress tracks match the reference palette.
- Card elevation remains restrained; borders and section rules do most of the structural work, as in the selected concept.

### Assets and icons

- Reused the actual eSheepNext app mark from the native project.
- Generated and integrated a consistent MiMo assistant avatar for the account surface.
- Replaced early generic sheep/scale glyphs with the closest production icon-library assets: Material Design Icons for sheep and Tabler's outline body scale.
- Remaining P3 difference: the library glyph geometry is not a pixel-identical tracing of the concept, but weight, color, size, and semantic placement match.

### Copy and visible content

- Above-fold labels, navigation items, alert titles/counts, recent-event rows, quick actions, metrics, and TMR meal values match the selected concept.
- Intentional state difference: the footer reads `演示数据` instead of `云端基础投影已同步` until an authenticated Supabase workspace is loaded. Cloud mode explicitly labels rule/TMR/catalog/insight previews so partial projection coverage is never presented as complete synchronization.
- No unapproved implementation-only hero or workspace label remains above the fold.

## Findings and fixes

- P0: none.
- P1: none.
- P2 fixed: header utility region originally sat too far right; constrained it to the concept width.
- P2 fixed: an unapproved `演示工作区` label changed above-fold composition; removed it.
- P2 fixed: the first 390 px build allowed the 650 px event table to widen the document to 707 px; constrained grid children and retained table-local scrolling. Final body width is 390 px.
- P3 fixed: the early generic scale icon diverged from the reference; replaced it with a closer Tabler outline body-scale asset and retained the closest available sheep-library glyph.
- P3 accepted: minute anti-aliasing, system-font metrics, and one-pixel source normalization remain platform-level differences.

## Functional QA

- Global search returns sheep and event matches and clears when navigating to another workspace.
- All eight primary navigation destinations render.
- TMR exposes plan, formula/production, and deviation-monitoring surfaces.
- Feeding exposes production records, ingredient-library, and recipe-management tabs. Entry flows preserve the App's controlled `早 / 中 / 晚 / 全天` meal semantics.
- Settings exposes Supabase email/password and Apple OAuth authentication, RLS-oriented cloud read behavior, projection-coverage labels, role capabilities, and an explicit production-write safety boundary.
- The Apple button is visible and enabled in the configured local preview; the browser was not sent through the external Apple consent screen during QA.
- Supabase Auth settings report Apple as enabled, but the read-only authorize smoke check currently returns `missing OAuth secret`; the UI maps that external configuration gap to a Chinese remediation message.
- The weight-record path closes the dialog, writes a new top ledger event, and displays `记录已写入演示台账。`.
- Browser runtime inspection found no console warnings or errors beyond Vite/React development informational messages.
- `npm run build` passes with code-split React, icons, Supabase, feature-page, and dialog chunks and no chunk-size warning.
- `npm run test:sites` passes 4/4 tests.

## Final assessment

The implementation is faithful to the accepted concept's layout, hierarchy, density, palette, visible content, and operational character. The only deliberate visual-state change is the honest demo/cloud sync label, and remaining icon/font differences are minor platform-level variations.

final result: passed
