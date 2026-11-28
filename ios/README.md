# Proteus iOS

SwiftUI client for a Proteus hub. The iPhone never runs sessions: it connects to a
workstation over the tailnet with `ws://host:port/v1` and speaks protocol v1–v10.

## Layout

- `ProteusKit/` — Swift package with every non-UI piece: frame Codable types, `HubClient`
  (`URLSessionWebSocketTask`, ping, backoff, seq catch-up), session/chat/model/account/task
  stores, the terminal store and input/resize encoding, formatting, token storage
  (`#if canImport(Security)` Keychain, in-memory on Linux), `AppearanceStore` +
  `PaletteEngine` (v7 custom colours), the bundled `palettes.json`, and the
  `proteus-probe` executable.
- `Proteus/` — app target: SwiftUI screens, the Metal wave shader, the SwiftTerm wrapper,
  assets, `Info.plist`.
- `project.yml` — XcodeGen input. SwiftTerm is pinned to exact version **1.20.0**; the
  `.xcodeproj` is generated and is not committed.

## Terminals

The Terminals section in the chats list shows every PTY open on the workstation, including
shells started on the desktop. Tap one to attach (the hub replays the buffer); "+" opens a
new shell after picking a folder (recent chat folders, the `fs.dirs` browser, or home).
Swipe a row to close it.

The terminal screen is SwiftTerm wrapped in a `UIViewRepresentable`. The shell is opened
only after the view has measured its real cols/rows; `term.resize` is debounced 100 ms on
rotation and keyboard changes. The accessory bar has Esc, Tab, one-shot Ctrl and Alt, the
four arrows (press and hold repeats), `| ~ / -`, Backspace and hide-keyboard. Pinch changes
the font size and is remembered. The background is transparent over the wave dither, and
the 16 ANSI colours are the readable palette from `docs/design/linux.md` §v6.

`plain: true` is sent by default so the prompt appears immediately. Settings → Terminals →
"Show shell greeting" sends `plain: false` for new shells. On foreground/reconnect the app
re-attaches every mounted terminal; replay-aware reset (`RIS`) prevents doubled output.

## Demo mode (offline screenshots)

Launch with `-ProteusDemo` to load offline demo data: four chats, the "Website" and
"Notes" projects, a running task, usage bars, models and one terminal. No socket is
opened and no frame is sent.

`-ProteusDemoScreen=<name>` opens a screen directly for screenshots:

| name | screen |
| --- | --- |
| `chats` (default) | chats list with the Terminals section |
| `agents` | demo chat with the Agents sheet open |
| `project` | project settings dialog, filled (with sub-agent fields) |
| `terminal` | terminal with output and the accessory bar |
| `settings` | Settings → Appearance |

CI runs these in the `ios` workflow after the IPA steps: it builds for the simulator,
boots the first available iPhone, installs, launches each screen and uploads
`ios/screens/*.png` as the `ios-screens` artifact.

## CI build

`.github/workflows/ios.yml` runs on every push that touches `ios/**` or `protocol/**`, and on
manual dispatch. On `macos-latest` it selects the newest Xcode, installs XcodeGen, generates the
project, runs `swift test` for ProteusKit, archives an unsigned Release build, zips
`Payload/Proteus.app` into `Proteus.ipa`, and uploads it as the `Proteus-ipa` artifact. It
then builds the Debug simulator app and captures the demo screenshots described above.

Download the artifact from the workflow run. Install it with **iloader**, which signs it with a
free Apple ID. A free-signed app has to be re-signed every 7 days.

## Install locally

Requires Xcode 26 (iOS 26 SDK, for the Liquid Glass branch) and XcodeGen:

```sh
cd ios
xcodegen
open Proteus.xcodeproj
```

SwiftTerm is resolved by Swift Package Manager at the pinned 1.20.0 tag.

## Tests on Linux

ProteusKit has no SwiftUI imports, so its logic is verified without a Mac:

```sh
cd ios/ProteusKit
swift test
```

The package uses swift-corelibs-foundation and `FoundationNetworking`. On Linux the Keychain
falls back to an in-memory store (tests use that path). A Swift 6 toolchain is enough; the
package targets Swift tools 6.0 with Swift 5 language mode.

## Read-only hub probe

`proteus-probe` connects, reads the welcome frame and exits. It prints counts only and never the
token. The token comes from the environment; do not put it on the command line:

```sh
cd ios/ProteusKit
PROTEUS_TOKEN="$(jq -r .token ~/.config/proteus/hub.json)" \
  swift run proteus-probe <host> <port>
```

Output is four lines (`sessions`, `models`, `accounts`, `projects`) and the process exits. It
sends only `hello`; it never sends a state-changing frame.

## Feature coverage

Chats (search, Projects + Chats, rename/move/stop/delete, project dialog with sub-agent tiers),
chat transcript (markdown, code blocks, thinking, tool cards, permissions, streaming,
follow-bottom), permission mode menu, mid-chat model change, `model_unavailable` notice with
"Use default", open-terminal-here, composer (multiline, photo attach downsampled to JPEG ≤1600 px,
send/stop, model menu), Agents sheet (tap an agent to scroll to its tool card), Terminals,
Settings (workstations and Keychain tokens, accounts/providers with adding, switching, sign-in and
key management, default model, text size, theme/palette/animated background and intensity).
Appearance also has five custom-colour slots synced through the hub (`appearance.setSlot` /
`appearance` broadcast, v7).

The full Linux → iOS audit is in `docs/design/ios-parity.md`. Notifications (ntfy) are v9 and
plain SSH without a hub is explicitly out of v8.

The SwiftUI, UIKit and SwiftTerm layers only compile on CI; `swift test` does not exercise them.
