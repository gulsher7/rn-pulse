# RN Pulse Implementation Plan

## Milestone 1 — Native shell and environment

- Create the SwiftUI macOS application.
- Add an environment/doctor screen.
- Detect xcrun, simctl, adb, Android SDK, and Maestro.
- Report missing dependencies clearly.

## Milestone 2 — Device discovery

- Discover Android targets through ADB/SDK tooling.
- Discover iOS simulators through simctl.
- Normalize both into a shared device model.
- Add device picker and refresh.

## Milestone 3 — Project and Maestro discovery

- Let the developer choose an RN project directory.
- Detect package.json and native project markers.
- Discover Maestro YAML flows.
- Show flow metadata and allow selection.

## Milestone 4 — Run a real flow

- Validate selected device.
- Run Maestro against the selected device.
- Stream stdout/stderr to the app.
- Show current test state and cancellation.
- Keep test failures separate from profiler failures.

## Milestone 5 — Native metrics

- Add Android CPU/memory/FPS collectors.
- Add iOS equivalents where reliable through native tooling.
- Define sampling and lifecycle management.
- Store timestamped normalized metric events.

## Milestone 6 — Dashboard and report

- Show live metrics.
- Show test timeline.
- Show summary and warnings.
- Export local JSON.

## Later

- Embedded live device view.
- Janky/frozen frame analysis.
- JS/UI thread instrumentation.
- Baselines and regression detection.
- Deeper Perfetto/xctrace integrations.
