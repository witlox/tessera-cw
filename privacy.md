# Tessera — Privacy Policy

**Effective: 2026-06-11**

Tessera is a single-player and multiplayer crossword game published by Pim
Witlox. This policy explains what data the app handles and what it does not.

## Short version

Tessera **does not collect any personal data**. It has no analytics, no
advertising, no third-party tracking, and no servers under our control.
Game progress is stored on your device; multiplayer is routed through
Apple's Game Center.

## Data the app stores on your device

The app writes a single JSON file in your device's **Application Support**
directory to remember an in-progress solo puzzle (which words you've
filled, which cells you've revealed, and your selection). This file lives
inside the app's sandbox and is removed when you delete the app or tap
"Discard solo game" inside the app. It never leaves your device.

The app also reads a bundled, read-only SQLite database (`tessera.sqlite`)
that ships inside the app's resources. It contains words and clues only.

## Data the app does *not* collect

- We do not collect or transmit your name, email, IP address, device
  identifiers, advertising identifier, contacts, photos, location, or
  any other personal data.
- We do not use Google Analytics, Firebase, Mixpanel, Sentry, Crashlytics,
  Adjust, AppsFlyer, Branch, or any other third-party SDK that profiles
  users.
- We do not run our own servers and do not maintain any database of users.
- We do not display advertisements.

## Multiplayer (Game Center)

If you choose to play a multiplayer match, the app uses Apple's
**Game Center** turn-based service:

- Your Game Center nickname and your in-game moves are visible to your
  opponent — that's how the match works.
- The match's state (whose turn it is, which letters have been placed,
  which cells have been revealed) is stored by Apple on Game Center's
  servers so the other player can resume the match on their device.
- We never see your Apple ID, your real name, or your email address. The
  app only ever knows your Game Center *player identifier*, which is an
  anonymous, app-scoped string assigned by Apple.

Apple's handling of Game Center data is governed by Apple's own privacy
policy: <https://www.apple.com/legal/privacy/>.

The Game Center multiplayer feature is optional. You can play Tessera
without ever signing into Game Center.

## Third-party software inside the app

Tessera embeds one third-party library:

- **GRDB** (<https://github.com/groue/GRDB.swift>) — a Swift wrapper around
  SQLite, used only to read the bundled word/clue database on your device.
  GRDB does not make network requests.

## Children

The app does not target children under 13 specifically, and it does not
collect any data from any user regardless of age. The Game Center
multiplayer feature inherits Apple's Game Center age requirements.

## Required-Reason API disclosures

In line with Apple's Privacy Manifest requirements
(`PrivacyInfo.xcprivacy` shipped inside the app bundle), Tessera declares
the following Required-Reason API categories:

- **File Timestamp** — used by the system when the app saves and reads its
  own in-progress solo game JSON file. (Apple reason code `C617.1`.)
- **System Boot Time** — used internally by SQLite (via GRDB) for query
  timing. (Apple reason code `35F9.1`.)

No other privacy-relevant APIs are accessed.

## Changes to this policy

If this policy changes, the updated text will be committed to this
repository and the effective date above will be updated. The git history
is the canonical change log.

## Contact

Questions about this policy: **pim@witlox.io**
