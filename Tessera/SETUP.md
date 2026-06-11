# Tessera — build + ship setup

## Prerequisites

- Xcode 15.0 or later (15.2+ recommended; tested on Xcode 26).
- `xcodegen` (`brew install xcodegen`).
- An Apple Developer Program enrollment (for Game Center + TestFlight +
  App Store submission). The library compiles fine without one; the iOS app
  builds & runs on simulator without one too. **Multiplayer needs it.**

## Local build

```bash
cd Tessera
xcodegen generate           # regenerates Tessera.xcodeproj from project.yml
open Tessera.xcodeproj
```

The generated `.xcodeproj` is git-ignored — always regenerate from
`project.yml`. Edit `project.yml`, not the project file.

In Xcode:
1. Select the **Tessera** scheme.
2. Choose an iPhone or iPad simulator.
3. ⌘R.

For device / Archive builds:
1. Tessera target → **Signing & Capabilities**.
2. Tick "Automatically manage signing".
3. Set **Team** to your Apple Developer team.
4. Build for a connected device or Archive for TestFlight.

Simulator builds need no signing (`project.yml` disables it for the
`iphonesimulator` SDK). Device builds use automatic signing — leave
`DEVELOPMENT_TEAM` blank in `project.yml` and set it once in Xcode so it
isn't committed.

To run the library tests headless:

```bash
swift test
```

## App Store Connect / Game Center

This is the half that has to happen on Apple's side before multiplayer
works. Solo play does not need any of this.

1. **App Store Connect → My Apps → New App**.
   - Bundle ID: `io.witlox.tessera` (matches `project.yml`). If you change
     it, edit `PRODUCT_BUNDLE_IDENTIFIER` and regenerate the project.
   - Platform: iOS.
   - SKU: anything stable, e.g. `tessera-001`.
2. **Certificates, Identifiers & Profiles → Identifiers**:
   - Open the app ID, enable **Game Center** capability, save.
3. **App Store Connect → Game Center**:
   - Enable Game Center for the app. Achievements/leaderboards optional.
   - There are no leaderboards or achievements in v1; you can leave both
     blank.
4. **In Xcode**:
   - Signing & Capabilities → make sure "Game Center" is listed (it should
     be, via `App/Tessera/Resources/Tessera.entitlements`).
   - Set your Team.
5. **TestFlight** (recommended for testing multiplayer end-to-end):
   - Archive → Upload to App Store Connect.
   - Add an internal tester, accept on a second device, try a match.

Game Center auth is best-effort; the **Multiplayer** entry point shows an
inline empty state if the local player isn't signed in.

## Updating the corpus

```bash
cd content
python3 build_content.py     # rebuilds tessera.sqlite
cp tessera.sqlite ../Tessera/Sources/TesseraKit/Resources/tessera.sqlite
swift test                   # corpus tests verify the schema invariants
```

The bundled DB is read-only; the app never writes to it.

## Things to know about the build

- The Swift package `Package.swift` declares iOS 17 / macOS 14 minimums so
  it can use `@Observable`. Bumping these affects the App Store rejection
  ceiling for older devices.
- `xcodegen` regenerates the project file deterministically. If two
  developers edit `project.yml`, the merge is text-based; the `.xcodeproj`
  itself is not committed.
- The app icon at `App/Tessera/Resources/Assets.xcassets/AppIcon.appiconset`
  is a 1024×1024 typographic "T" rendered by a Swift script. Replace with
  whatever final art you ship — Xcode warns if any required icon size is
  missing.
- `App/Tessera/Resources/PrivacyInfo.xcprivacy` declares no tracking, no
  data collection, and the Required-Reason API categories actually touched
  (file timestamps for solo-game persistence; system boot time via SQLite).
  Update if you add analytics or networking outside GameKit.
