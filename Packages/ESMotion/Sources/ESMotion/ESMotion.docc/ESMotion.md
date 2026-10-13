# ``ESMotion``

Build interruptible, accessible motion without replacing an application's routing or business state.

## Overview

ESMotion separates stable host state from per-frame rendering. A host owns one ``MotionEngine``, while active scenes subscribe to its shared display coordinator through ``MotionTimelineView``.

Use ``MotionTransitionHost`` with ``SwiftUI/NavigationStack`` to register shared-element sources and destinations while keeping system navigation semantics.

## Topics

### Engine

- ``MotionEngine``
- ``MotionHost``
- ``MotionTimelineView``
- ``MotionBudget``

### Transitions

- ``MotionTransitionHost``
- ``MotionTransitionID``
- ``MotionTransitionSpec``

### Assets and scenes

- ``MotionLottieView``
- ``MotionMetalParticleView``
- ``MotionParticleScene``

### Documents

- ``MotionDocument``
- ``MotionDocumentValidator``
