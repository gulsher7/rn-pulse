# RN Pulse Architecture

## MVP

The first vertical slice is intentionally small:

Project -> Device -> Maestro Flow -> Run -> Collect native metrics -> Report.

## Layers

### Device Engine

Discovers and describes local Android and iOS targets.

Android:
- adb devices
- Android SDK emulator metadata

iOS:
- xcrun simctl list devices
- xcrun simctl list runtimes

### Test Engine

Uses Maestro CLI for real-device UI automation. Existing flows remain the source of truth.

### Performance Engine

Collectors are platform-specific and emit normalized metric events.

Initial collectors:
- CPU
- Memory
- FPS/frame timing
- App startup

Future collectors:
- JS thread
- UI thread
- freeze detection
- Fabric/Hermes metrics

### Metrics Engine

Normalizes platform output and evaluates thresholds without inventing unavailable values.

### Report Engine

Stores a local run result and exposes a summary suitable for a SwiftUI dashboard and JSON export.

## Design Constraints

- macOS only
- local execution only
- no backend
- no cloud services
- low overhead
- asynchronous subprocess management
- explicit unsupported/unavailable states
- Android and iOS code isolated behind shared protocols
