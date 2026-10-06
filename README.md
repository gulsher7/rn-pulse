# RN Pulse

Local macOS performance testing tool for React Native Android and iOS apps.

## Status

Initial repository bootstrap. The implementation will follow the MVP described in the project task specification.

## Goals

- Discover local Android emulators and iOS simulators.
- Discover and run existing Maestro flows.
- Collect lightweight CPU, memory, FPS/frame, and startup metrics.
- Show test progress and performance metrics in one native macOS UI.
- Keep all execution local with no backend or cloud dependency.

## Planned stack

- Swift
- SwiftUI
- ADB / Android SDK
- xcrun / simctl / Xcode tooling
- Maestro CLI

## Architecture

The application will be split into device discovery, Maestro execution, performance collectors, normalized metrics, and reporting so Android and iOS implementations remain isolated.

## Development

The project is intentionally bootstrapped before the first native macOS implementation so the development history remains incremental and easy to review.
