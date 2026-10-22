# 3.2 (112) poster/editor regression — 2026-10-22

## Baseline and evidence limits

Reviewed main `a9b3d007a1966928d83b99ca0dc7583337fa8ebc`. PR #11 introduced the editor; PR #12 fixed member sharing; PR #13 fixed a Files-panel test. No open PR duplicated this task at review time. The three poster implementation files and `SheepSharePosterTests.swift` are unchanged between PR #12's merge (`55ae8b0f959e62cd90571487712151a6a6c26740`) and this baseline. This is a source regression of the functionality reported in build 112, not a claim that the TestFlight binary has been independently installed or its archive SHA verified.

Scanned all unit, UI and performance test sources and test/CI scripts for poster/share/template coverage before adding cases. Existing coverage is 20 `SheepSharePosterTests` and three role entry/share/export UI tests. The role tests and the existing canvas/style/font/name-alignment checks are retained without duplicating them.

## Coverage audit

| Area | Existing evidence | Added regression |
| --- | --- | --- |
| Canvas, styles, fonts, bilingual names | 20-test suite includes rendering and font registration | Reuse existing tests |
| Text, Chinese font, geometry, front/back layers | Model/render examples, no editor interaction | Three style-specific native editor flows with state assertions |
| Canvas dragging | None | Drag actual canvas, verify logical displacement and undo |
| Photo crop | No control interaction | Zoom and both offsets on asymmetric synthetic image; undo/reset |
| Color and hiding | No native control interaction | Native ColorPicker, visibility, undo |
| Reset, undo, reopen | Direct customization reset only | Native controls and editor dismissal/reopening |
| Save, process restart, apply | JSON round-trip only | Actual Save UI, terminate/relaunch, persisted template menu |
| Cross-sheep data | A subset of live overrides | Distinct A/B photos, pedigree and reproduction; exhaustive live-field disk tests across styles and ewe/ram/unknown |
| Cross-style application | None | Save minimal design, apply from magazine, reopen |
| Preview/export consistency | Nonempty/different rendered images; share panel opens | Real thumbnail and preview screenshots vs rendered pixels, real UIActivity PNG write/readback, exact preview/export bytes |
| Corrupt template file | None | Throw and preserve original bytes |

New cases: 9 UI tests and 3 unit/integration tests. The UI tests observe DEBUG-only JSON accessibility values; all mutations go through actual production UI controls. State assertions are not substitutes for screenshots, image comparisons, or real-device acceptance.

## Isolation and share boundary

- Launch requires `--design-acceptance --design-reproduction --design-sheep-detail --design-poster --design-fixture-id <UUID>`.
- Uses existing local-only database and `allowsRemoteConnections: false`. Seeding verifies the fixture account and local-only route. No production service, data, or cloud setting is used.
- Two fictional sheep (`QA-001`, `QA-002`) receive different generated color-block images and parents. Existing reproduction fixtures have different postpartum dates. Photo hashes pass through the normal local asset reader.
- Templates, images and share output live under a UUID-specific `DesignAcceptance/Poster` directory. Tests never read, overwrite or remove the normal personal-template store. Relaunch reuses the same UUID; every new test uses a fresh one.
- Diagnostics and the `Save regression PNG` activity are compiled only in DEBUG and enabled only for this fixture. Release has its original system sharing behavior.
- The test activity receives the actual `UIActivityViewController` item, encodes it to PNG, writes it to disk, reads and decodes it. This checks the app-to-system-share boundary and local file round-trip. It does **not** certify Apple Photos, AirDrop, Files, WeChat or another external destination.
- User-added captions/artwork remain design assets. Built-in live fields and sheep photo overrides are sanitized. A user deliberately typing animal facts into a freeform caption remains freeform content; no semantic redaction is claimed.
- Personal templates are local to this device. Cross-device sync is not a feature or an acceptance criterion.

## Run on a Mac with stable Xcode

The synchronized source groups include the new files automatically. The existing `iOS runtime regression` PR workflow runs the nine poster UI cases first, then skips that class in the remaining UI pass to avoid duplication; the full unit suite includes the 23 poster cases. The previous complete baseline run took 47 minutes, so the job budget is raised from 60 to 90 minutes. The new UI group has a 30-minute budget and a 360-second per-test limit, with zero skips and exactly nine discovered tests required. No existing regression gate is removed.

For focused execution, replace the simulator ID with an available disposable simulator:

```sh
xcodebuild test -project eSheepNext.xcodeproj -scheme eSheepNextUI \
  -configuration Debug -destination 'platform=iOS Simulator,id=<SIMULATOR-UUID>' \
  -only-testing:eSheepNextUITests/SheepSharePosterEditorUITests \
  -parallel-testing-enabled NO -resultBundlePath /tmp/poster-editor-112.xcresult

xcodebuild test -project eSheepNext.xcodeproj -scheme eSheepNext \
  -configuration Debug -destination 'platform=iOS Simulator,id=<SIMULATOR-UUID>' \
  -only-testing:eSheepNextTests/SheepSharePosterTests \
  -parallel-testing-enabled NO -resultBundlePath /tmp/poster-unit-112.xcresult
```

Do not accept a zero-discovery, skipped or failing result. Expected discovery: 9 UI / 23 poster unit tests. Inspect attachments for text/glyphs, crop, layer placement and reset. Pixel comparison normalizes to 90×160, excludes five-pixel edges for rounded corners and allows mean RGB error below 5%; this tolerance still needs validation on the first simulator run and must not be widened solely to hide a failure.

## Validation status

- Local Linux: CI-mode static gate passed (`VERIFY_PUBLIC_CONFIG=0 VERIFY_ALLOW_LEGAL_PLACEHOLDERS=1 ./tools/verify_local.sh static`). This is not Swift compilation or simulator execution.
- Swift app/UI-test compilation: passed for `1652600` in iOS runtime run `39738921054`. This does not mean the UI tests passed. The follow-up CI grouping change runs poster UI tests first.
- Simulator interaction results: pending. New tests must pass before the draft is considered ready.
- Repository verification run `39738921124`: static, Web and disposable database passed; backend stopped at existing Vitest/@vitest/mocker dependency advisories (GHSA-qxg6-89mg-rqv8 and GHSA-xp26-3454-mjgp). No backend files are changed by this PR.
- Physical device / installed TestFlight 112: not performed.
- No runtime defect is confirmed from source inspection alone; no speculative product behavior fix is included.

## Remaining physical-device acceptance

Use a disposable local test farm and synthetic images, never a production farm. Install the actual TestFlight build 112 and record device, OS and build. Exercise native PhotosPicker replacement and cancellation, Chinese IME/multiline text, color controls, font selection, drag and layer order, photo crop, undo, reset, save/relaunch and A→B reuse. Test a ram and missing-photo sheep as well as two ewes. Save the shared image through a real system destination and reopen it; compare with the preview including dimensions, crop, characters and dynamic facts. Record failures with screenshots and image files. Report these separately from DEBUG simulator results and from any subsequently fixed build.
