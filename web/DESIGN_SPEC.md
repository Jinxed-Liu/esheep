# eSheepNext Web — Daily Field Ledger

Source visual truth: `design-reference.png`.

## Layout

- Desktop reference viewport: 1488 × 1058.
- 76 px horizontal app header with a 220 px cobalt brand block.
- Open white/very-light-gray canvas with 24 px outer gutters.
- Home workbench uses a 60/40 two-column ledger: the left column owns alerts, recent events, and sync state; the right column owns compact metrics, six quick actions, and TMR execution.
- Panels are restrained white surfaces with 1 px cool-gray borders, 3–6 px radii, and almost no shadow.
- Below 1080 px the workbench becomes one column; navigation remains horizontally scrollable. Below 720 px utility controls wrap and tables become horizontally scrollable.

## Tokens

- Brand: `#0867e8`; deep brand: `#075dcc`; active rail: `#0b73f6`.
- Canvas: `#f8fafc`; surface: `#ffffff`; muted surface: `#f5f7fa`.
- Text: `#172033`; secondary text: `#687386`; borders: `#dfe4eb`.
- Danger: `#e9384f`; warning: `#ff9700`; success: `#23ad49`.
- Typography: PingFang SC / SF Pro / Inter-compatible system stack. Large date 44/1.15, section titles 22/1.3, body and UI chrome 14–18 px.
- UI icons: Phosphor outline family, regular weight, round caps, 20–30 px, cobalt by default.

## Component families

- Header navigation with active underline.
- Ledger section with a cobalt left rail.
- Dense bordered table/list rows.
- Square quick-action controls with icon, label, hover/focus/active states.
- Compact statistic strip with separators.
- TMR meal timeline with period marker, planned/actual amount, and progress bar.
- Modal record sheet, search result panel, farm switcher, and account menu.

## Core workflow

1. Resolve today's alerts and open the relevant workspace.
2. Start a production record from the top-level action or one of six quick actions.
3. Confirm the record locally; the event ledger updates immediately.
4. Sign in to Supabase from Settings to load the member's real farm projections under existing RLS.
5. Keep real cloud mutations gated until the web client carries the same command, revision, device, audit, and replay guarantees as the iOS app.
