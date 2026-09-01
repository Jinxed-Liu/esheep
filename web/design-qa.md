# eSheep+ Web redesign QA

- Selected reference: `design-qa-assets/home-redesign-option-1.png` (1487 × 1058)
- Browser implementation: `design-qa-assets/home-redesign-implementation.png` (1487 × 1058)
- Combined comparison input: `design-qa-assets/home-redesign-comparison.png`
- Mobile evidence: `design-qa-assets/home-redesign-mobile.png` (390 × 844)
- Browser state: authenticated cloud workspace; unauthenticated users are held at the eSheep+ login screen and no demo route is available.

## Visual fidelity

- P0: none. The App shell, navigation, home information hierarchy, primary action, alert/status groups, and TMR context all render and remain usable.
- P1: none. The implementation matches the selected 142 px rail, 95 px top bar, 1487 × 1058 desktop canvas, main/right-column split, content edges, vertical rhythm, blue/white palette, thin separators, and compact row anatomy.
- P2: none requiring correction. Intentional product-truth differences are the direct Phosphor `Tag` glyph in place of the generated sheep glyph and an explicit `云端读取已连接` state; unauthenticated visitors never enter a farm workspace.
- Copy check: primary navigation, quick actions, alert labels/counts, production status, and TMR plan/actual labels match the selected direction. Dynamic farm/account/cloud values remain data-driven.
- Responsive check: 390 × 844 has no page-level horizontal overflow; the rail becomes a five-item bottom navigation and tables keep their own horizontal scroll.

## Interaction acceptance

- All five App destinations open: 首页、洞察、录入、投喂、搜索.
- Browser-only draft weighing flow submits and appears in recent events without claiming a cloud write.
- Unified search opens the selected sheep detail.
- Feeding opens TMR completion/deviation monitoring with three meal rows.
- A fresh browser tab completed the primary-route sweep with no console errors or warnings.

final result: passed

## App analytics parity QA

- Desktop evidence: `design-qa-assets/insights-app-parity-desktop.png` (1440 × 1000 viewport)
- Mobile evidence: `design-qa-assets/insights-app-parity-mobile.png` (390 × 844 viewport)
- Live workspace: the signed-in Supabase farm at the default local URL; no demo values were used for the analytics acceptance.

### Reference mismatch ledger

1. Rail and top bar: matches the selected reference's fixed blue brand rail, white account bar, selected-route treatment, and left content origin.
2. Main canvas: matches the reference's blue-white surface, thin separators, square-soft cards, and wide desktop rhythm; the analytics page intentionally uses the full content width instead of the home-only action sidebar.
3. KPI anatomy: the four analytics totals use the same icon/label/value/unit hierarchy as the home livestock, pen, and feeding totals, with App-specific sample units retained.
4. Destination cards: the two-column desktop grid keeps the reference's row geometry and chevrons; descriptions are denser because each destination must expose its statistical boundary before opening.
5. Right-side operations column: intentionally absent on the analytics route because new-record actions and today's TMR are home context, not analytics context; adding them here would change the selected App information architecture.
6. Typography and color: title weight, muted supporting copy, App blue accent, status green, and border contrast remain within the selected system; analysis-specific warnings use the same restrained notice treatment.
7. Mobile collapse: the rail becomes the five-item bottom navigation, KPI rows become one column, and the 390 px viewport reports `scrollWidth === innerWidth`; no page-level horizontal overflow was found.
8. Data-state difference: the live farm currently has no qualifying recent feed/trough intervals, so the App-correct result is `0` with an explicit boundary explanation rather than the reference mockup's illustrative TMR values.

### Analytics interaction acceptance

- All four destinations load from live cloud projections: 增重、羔羊（产羔/断奶）、繁殖（胎间距/产后天数/品种）、采食营养.
- Historical lamb offspring stored with `sexRawValue` render as concrete 公/母 values.
- The 7-day and 30-day feeding presets switch without the former per-pen full sheep-day recomputation stall.
- The live event table contains 637 rendered rows; the placeholder scan found no blank object/value cells, `对象某某`, `未知对象`, `资料未展开`, or `[object Object]` values.
- Browser console acceptance: no errors or warnings.

analytics result: passed
