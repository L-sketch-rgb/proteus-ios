# Proteus for iOS

The SwiftUI iPhone client for a Proteus hub, plus the wire protocol it speaks.

This repository holds **only the iOS app** and what its build needs. The hub, the desktop
application and the design documentation live elsewhere and are not part of this tree.

## Layout

- `ios/Proteus/` — the app target: SwiftUI screens, the Metal wave shader, the SwiftTerm
  wrapper, assets. Generated Xcode project; `ios/project.yml` is the XcodeGen input.
- `ios/ProteusKit/` — Swift package with everything that is not UI: frame types, the
  WebSocket client, the session/chat/terminal stores, formatting, Keychain token storage.
  It has no SwiftUI imports, so `swift test` runs it on Linux too.
- `protocol/` — the hub ↔ client protocol specification and the test vectors for its
  key exchange.
- `.github/workflows/ios.yml` — the whole build: `swift test`, an unsigned Release archive
  and `.ipa`, then a Debug simulator build that installs the app and captures screenshots
  of each demo screen.

## Building

The app itself needs macOS with Xcode 26 (iOS 26 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
cd ios
xcodegen
open Proteus.xcodeproj
```

SwiftTerm is pinned to 1.20.0 and resolved by Swift Package Manager.

Nothing here is signed. A CI run produces an unsigned `Proteus.ipa` as the `Proteus-ipa`
artifact; signing it for a device is up to you (a free Apple ID signature expires after
seven days).

The non-UI logic builds and tests anywhere with a Swift 6 toolchain:

```sh
cd ios/ProteusKit
swift test
```

## Demo mode

The app opens on a "no workstation yet" state. For screenshots and UI work it can run
entirely offline:

- `-ProteusDemo` — load offline demo data (four chats, two projects, a running task, one
  terminal). No socket is opened.
- `-ProteusDemoScreen=<chats|agents|project|terminal|settings>` — open a screen directly.

CI uses both to capture the screenshots it uploads.

## Licence

MIT — see [LICENSE](LICENSE).
