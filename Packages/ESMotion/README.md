# ESMotion vendored libraries

Source: https://github.com/Jinxed-Liu/ESMotion

Upstream revision: `c236df09ee8004471ce2c2427f1a56027a49ff23`, matching the
application's previously resolved ESMotion dependency. `LICENSE` and `NOTICE`
are retained from that revision.

This copy keeps the five library products and the Metal shader resource. The
upstream CLI, Studio, Gallery, and package test targets are omitted. Lottie's
upstream dependency requirement remains `from: "4.6.0"`; the application's
`Package.resolved` continues to select its version.

Compatibility changes:

- Minimum iOS version is 17. macOS remains 26 and Swift tools remain 6.2.
- On iOS 18 and later, transition sources and destinations keep the native zoom
  transition. On iOS 17, they use the standard `NavigationStack` transition.
- `isolated deinit`, which requires the iOS 18.4 concurrency runtime, is replaced
  with cleanup that works on iOS 17. Display driver cleanup stays on MainActor;
  its display-link target captures the coordinator weakly so teardown can run.
  Notification observers remain owned until synchronous teardown.

When updating from upstream, start from the recorded revision, preserve these
compatibility changes, and build the app with an iOS 17 deployment target. Verify
navigation on iOS 17 as well as the zoom transition on newer systems. This package
is referenced by `Packages/ESMotion` in the Xcode project so building the app does
not require a sibling ESMotion checkout.
