# Saros Harmonic Journal

Native SwiftUI prototype for a private, local-first Saros harmonic journal.

The app has two halves:

- a bundled solar eclipse/Saros catalog backed by the compact data files already in this repository;
- a local journal where user-created threads are anchored to dates, Saros series, and octal harmonic clock readings.

## Project Layout

- `SarosHarmonicJournal.xcodeproj` - generated Xcode project.
- `SarosHarmonicJournal/App` - SwiftUI app entry point, tab shell, dependency wiring.
- `SarosHarmonicJournal/Domain` - eclipse models, Saros clock logic, resonance detection.
- `SarosHarmonicJournal/Data` - SwiftData models for tracked entities and journal records.
- `SarosHarmonicJournal/Services` - eclipse service, notification scheduling, export, local server, media/audio helpers.
- `SarosHarmonicJournal/Views` - Clock, Capture, Catalog, Archive, and Settings screens.
- `SarosHarmonicJournalTests` - unit tests for clock math, resonance grouping, entity creation, and export shape.

## Architecture Notes

UI code talks to `EclipseService` and `SarosClockService` protocols. `BundledSolarEclipseService` currently reads the repo's compact binary solar data directly from the app bundle. `CPlusPlusEclipseService` is the explicit adapter seam for the production Objective-C++ or Swift C++ interop bridge; it currently delegates to the bundled reader so the app is usable before the native library is linked.

SwiftData stores:

- `TrackedEntity`: anchor/thread metadata, selected Saros series, harmonic depth, notification settings.
- `JournalRecord`: text, emoji, media references, Saros clock metadata, trigger type, optional location.

Media files are copied into the app documents directory and referenced by local path. Export writes `archive.json`, `entities.json`, `records.json`, and a `media` folder into Documents.

## First Run

Open the project in Xcode:

```bash
open SarosHarmonicJournal.xcodeproj
```

Recommended simulator target: iPhone 16 Pro or newer. The app requires iOS 17+ because it uses SwiftData.

## Tests

Run the unit tests from Xcode or with:

```bash
xcodebuild test -project SarosHarmonicJournal.xcodeproj -scheme SarosHarmonicJournal -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

For a compile-only check when simulator runtimes are not installed for the active Xcode SDK:

```bash
xcodebuild build -project SarosHarmonicJournal.xcodeproj -target SarosHarmonicJournalTests -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO
```

## C++ Bridge TODO

Replace the forwarding implementation in `CPlusPlusEclipseService` with an Objective-C++ adapter or Swift C++ interop layer that calls the existing eclipse library. Keep the protocol surface stable so SwiftUI screens and clock logic do not depend on raw C++ types.
