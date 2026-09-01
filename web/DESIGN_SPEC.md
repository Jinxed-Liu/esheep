# eSheep+ Web — App-aligned Field Briefing

Source visual truth: `design-qa-assets/home-redesign-option-1.png`.

## Layout

- Desktop reference viewport: 1487 × 1058.
- 142 px fixed left rail and a 95 px quiet top bar. The rail owns only the five App destinations; the top bar owns farm switching and the account/avatar menu.
- Open true-white / very pale cool-blue canvas. The main column owns the date/weather briefing, sync truth, three metrics, operational alerts, and production-status links.
- A narrow contextual right column owns one primary `新建记录` action, six lightweight quick-operation rows, and today’s feeding/TMR context.
- Use open bands and row separators first. Borders are subtle and purposeful; nested cards, bento grids, oversized rounded wrappers, and decorative filler are prohibited.
- Below 1120 px the contextual column moves beneath the briefing. Below 760 px the left rail becomes a five-item bottom navigation, the top bar stays visible, metrics wrap, and wide data tables scroll inside their own containers.

## Tokens

- Brand: `#0b5fe9`; strong brand: `#0454dd`; active tint: `#edf4ff`.
- Canvas: `#f8fbff`; surface: `#ffffff`; subtle surface: `#f5f8fc`.
- Text: `#101b33`; secondary text: `#667187`; borders: `#dfe6ef`.
- Danger: `#e92846`; warning: `#f58b00`; success: `#20a946`.
- Typography: PingFang SC / SF Pro / Inter-compatible system stack. Date 50–56/1.08 on desktop, page headings 30–36, section titles 18–20, UI chrome and body 14–16.
- UI icons: direct Phosphor outline imports, regular/medium weight, optically aligned at 18–28 px. Do not ship handcrafted SVG substitutes.

## Component families

- App rail with selected blue tint and a compact mobile bottom-nav variant.
- Quiet top bar with farm switcher and account menu.
- Field-briefing header with date, weather/location context, sync truth, and three inline metrics.
- Operational rows, status rows, quick-operation rows, and TMR meal rows with lightweight separators and visible hover/focus states.
- App-aligned hub groups for Records, Feeding/TMR, Insights, Search, and avatar-owned Settings.
- Modal record sheet, entity detail pane, filter/search controls, export actions, cloud projection notices, and explicit draft states.

## Core workflow

1. Read today’s status on Home and open sheep, pens, alerts, or a quick operation without crossing into a different top-level module.
2. Use Records for daily entries, sheep movement, reproduction, production batches, care management, and event history.
3. Use Feeding for direct feed, trough observations, TMR production/planning/monitoring, nutrition analysis, history, ingredients, and inventory.
4. Use Insights for App-matched analysis destinations and the assistant entry; use Search as its own top-level destination.
5. Confirm browser interactions locally; cloud-mode mutations remain explicitly drafted until the Web implements the App’s command validation, device identity, authority generation, entity revision, audit, Outbox, and replay guarantees.
