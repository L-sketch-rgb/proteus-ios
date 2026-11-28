# Proteus hub protocol v1

Transport: one WebSocket per app at `ws://<tailnet-ip>:7878/v1`. Every frame is
one JSON object with a `t` (type) field. Requests from the app may carry `rid`
(a request id string), and the hub echoes it in the reply (`ok` / `err`). The
TypeScript source of truth is `hub/src/types.ts`; this file describes it.
The hub also answers on `ws://127.0.0.1:7878/v1` when `bind` names a tailnet
address (v13 §3), so an app on the hub's own computer can connect over loopback
while Tailscale is down. `welcome` is the same on both listeners.

## 0. Identity and channel (v14 phase A)

Everything below is additive: a socket whose first frame is `hello {token}` keeps
the legacy path of §1 for one release (the hub logs `proteus-hub: legacy auth`
once per such socket). The TypeScript source of truth is `hub/src/identity.ts`,
`hub/src/psc.ts` and `hub/src/link.ts`; the shared vectors are
`protocol/psc1-vectors.json`.

### 0.1 Device keys and ids

Every device (hub or app) creates once:
- an X25519 key pair (`xpub`/`xpriv`, 32 bytes each) for PSC1;
- an Ed25519 key pair (`spub`/`spriv`) for signing the device list.

Device id = `hex(SHA-256(spub))[0..16]`: 32 lowercase hex characters. Wire ids
are that hex string; the app displays them in groups of four. The account id is
the id of the first device and never changes; the app displays its first four
groups.

The hub stores `device.json` and `account.json` beside `hub.json` (both mode
0600 in a 0700 folder); the desktop stores the same two files in
`PROTEUS_SETTINGS_DIR` (default: the app config folder).

`device.json` = `{v:1, id, name, kind:"hub"|"desktop"|"ios", xpub, xpriv,
spub, spriv, createdAt}` — all keys hex. A corrupt file is an error; the hub
never replaces it (a new key would change the device id).

### 0.2 The signed device list

`account.json` = `{v:1, accountId, rev, prev, homeHub, devices:[Device],
signer, sig, hash}` where
`Device` = `{id, name, kind, xpub, spub, addedAt, addedBy}`.

- The signed payload is canonical UTF-8 JSON of
  `{v, accountId, rev, prev, homeHub, devices}` with the keys in exactly that
  order and each device's keys in `id, name, kind, xpub, spub, addedAt, addedBy`
  order (the order this document lists).
- `sig` = Ed25519(signer's `spriv`, signed payload), hex.
- `hash` = hex(SHA-256(signed payload)). Revision `rev`'s `prev` is revision
  `rev-1`'s `hash`; revision 1 has `prev: ""`.
- A device accepts a list only when the Ed25519 signature verifies (with
  libsodium `crypto_sign_verify_detached`) against the signer's `spub` from its
  own copy, the recomputed SHA-256 of the canonical bytes equals `hash`,
  `accountId` is unchanged, `rev` is exactly the next revision, and `prev`
  equals the current `hash`. A first list (arriving in `link.ok`) is accepted
  when it self-verifies against the signer named inside it. `homeHub` must be a
  device in the list. A bad signature is rejected and logged. The first run of
  the first device creates revision 1 with itself as `homeHub`.

### 0.3 Linking (frames on a plain socket)

An authenticated client asks for a code:
`{t:"link.code", rid?}` → `{t:"link.code", rid?, code:"XXXX-XXXX-X",
payload:"proteus://link?v=1&host=…&port=…&code=…&fp=…", expiresAt}`.
The code is 9 Crockford base32 characters (alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`,
I/L read as 1 and O as 0), valid for 10 minutes, one use. A new `link.code`
replaces the previous one. `fp` is the hub's signing-key fingerprint, its
device id. Five wrong attempts within a minute pause all attempts for one
minute.

The new device sends, as the first frame of its own plain socket:
`{t:"link.hello", v:1, nonce, devicePub:{xpub, spub}, name, kind, mac}` where
`nonce` is 16 random bytes base64, the keys are hex, `name` is 1–64
characters, and

```
K         = HKDF-SHA256(UTF-8(code), salt = UTF-8("proteus-link-v1"), info = "", 32)
transcript= UTF-8("link.hello|1|" + nonce + "|" + xpub + "|" + spub + "|" + name + "|" + kind)
mac       = hex(HMAC-SHA256(K, transcript))
```

`code` is the 9 characters without dashes. The hub checks the MAC in constant
time. Any failure (unknown, expired, paused, wrong MAC) is the same reply:
`{t:"err", code:"link_failed"}` then close. Success:

`{t:"link.ok", rid?, v:1, from, eph, nonce, box}` — `from` is the hub's device
id, `eph` its 32-byte ephemeral X25519 public key (base64), `nonce` 12 random
bytes (base64), and

```
boxKey = HKDF-SHA256(UTF-8(code) ‖ X25519(hub_eph, devicePub.xpub), salt = "", info = "", 32)
box    = base64(ChaCha20-Poly1305(boxKey, nonce, plaintext = UTF-8(JSON), aad = ""))
```

The box's JSON is `{account: <signed device list>, homeHub, hubUrl,
hub:{id, name, xpub, spub}}`. The hub appends the new device, signs revision
`rev+1`, saves it, broadcasts `{t:"account.devices", account}` to every
PSC1-authenticated (linked) socket, and closes the plain socket; the device
reconnects with PSC1. A legacy-token socket never receives the device list.

An authenticated client removes a device with `{t:"device.remove", rid?,
id}` → `ok`, then the same broadcast; live channels of the removed device are
closed. A hub cannot remove itself.

A PSC1 channel renames its own device with `{t:"device.rename", rid?, name}`.
`name` is trimmed and must be 1–64 characters. The hub changes only the
sender's device, signs revision `rev+1`, saves it, replies `ok`, then
broadcasts `{t:"account.devices", account}` to PSC1 channels. A device may not
rename another device, and a legacy-token socket is refused.

### 0.3.1 Presence overlay

The hub tracks `lastSeen` for each device id: the later of its last PSC1
handshake and its last decrypted frame, rounded down to the minute. The
`account.devices` frame carries it beside the signed list:

`{t:"account.devices", account:<signed list>, presence:{"<deviceId>":"<ISO 8601>"}}`

`presence` is unsigned, is not part of the canonical bytes or the hash chain,
and may be absent. A device shows its own entry as "now" while its channel is
open, and other devices' times as last seen.

### 0.3.2 Catching up on a revision gap

A device that receives a list whose `rev` is more than one past its own, or
whose `prev` does not match its current `hash`, asks on its PSC1 channel:
`{t:"account.history", rid?, fromRev}` → `{t:"account.history", rid?,
lists:[...]}`. `lists` holds every signed revision after `fromRev`, oldest
first, at most 200; a client still behind asks again from the last revision it
accepted. The hub persists the chain beside `account.json` and serves only
PSC1-authenticated sockets.

The device verifies and applies each list in order with the same rules as a
live list, then accepts the live one. A chain that fails verification is
rejected and logged; the device keeps its last good list.

### 0.4 PSC1 handshake

The socket's first frame may be `{t:"psc.hello", v:1, from, eph, nonce, rid?}`:
`from` is the sender's device id (hex), `eph` its fresh X25519 ephemeral public
key (base64, 32 bytes), `nonce` 16 random bytes (base64). A device not in the
signed list, or a malformed hello, gets `{t:"err", code:"unknown_device"}`
(or `bad_request`), and the socket closes.

The responder replies with its own `{t:"psc.hello", v:1, from, eph, nonce}` in
the clear. Let the initiator be `i` and the responder `r`:

```
ss   = X25519(e_i, e_r) ‖ X25519(e_i, s_r) ‖ X25519(s_i, e_r) ‖ X25519(s_i, s_r)
salt = SHA-256(nonce_i ‖ nonce_r)
k_i2r = HKDF-SHA256(ss, salt, info = UTF-8("psc1 i2r"), 32)
k_r2i = HKDF-SHA256(ss, salt, info = UTF-8("psc1 r2i"), 32)
```

The hub then sends the normal `welcome` frame (§1) inside the channel; a PSC1
client sends no `hello {token}`. The `welcome` gains `device` (this hub's
`{id,name,kind,xpub,spub}`) and `account` (the signed device list).

### 0.5 PSC1 frames

Every following frame in either direction is

`{t:"psc", n:<counter>, c:<base64>}`

- `counter` starts at 0 and increments by one per direction; both directions
  have independent counters and keys, and a counter is never reused.
- nonce = 96-bit little-endian counter (12 bytes, bytes 8–11 zero).
- aad = `UTF-8(from) ‖ UTF-8(to) ‖ LE64(counter)`, where `from`/`to` are the
  sender's/receiver's 32-character hex device ids and the counter is 8-byte
  little-endian.
- plaintext = UTF-8 of one ordinary protocol frame (`{"t":…}`).
- `c` = base64(ChaCha20-Poly1305(key, nonce, plaintext, aad)).
- A counter at or below the last one seen is a replay: drop it and close the
  socket. A frame that does not authenticate closes it too.
- After 2^32 frames in either direction, or 24 hours, the channel needs a fresh
  handshake: the hub closes with code 4002 `rekey` and the app redials.

### 0.6 Vectors

`protocol/psc1-vectors.json` holds full vectors: both static key pairs, both
ephemeral key pairs, both hellos' nonces, the expected shared secret, salt,
`k_i2r`, `k_r2i`, and for each direction one plaintext frame with its counter,
aad and ciphertext. They are generated by
`cd hub && node scripts/gen-psc1-vectors.ts --write` and re-derived by
`hub/test/psc.test.ts`; the desktop's selftest 42 checks the same file.

## 1. Handshake
App's first frame: `{t:"hello", token, client:"ios"|"linux"|"test", version:1}`
Hub replies: `{t:"welcome", hubVersion, accounts:Account[], active:string, sessions:SessionInfo[], projects:string[], projectDefs:ProjectDef[], models:ModelInfo[], defaultModel:string, terms:TermInfo[], appearance:{slots:AppearanceSlots}, drafts:{sessionId:DraftWire}, queues:{sessionId:QueueItem[]}, pins:{sessionId:Pin[]}, notifications:{enabled, server, topic}, features:string[], presets:Preset[]}`
`features` lists the optional capabilities this hub supports (v10 §15.1), so an
app can disable a control whose hub is older instead of failing at use time.
Known values: `fs`, `pins`, `resend`, `notices`, `presets`, `questions`,
`tool_output`, `fs_roots` (v13 §2.1: workstation roots, `fs.find`, `fs.download`),
`fs_places` (v17: grouped roots with places/devices, `fs.info`, `fs.space`).
An app must treat an unknown value as a feature it does not use.
`presets` is the stored agent presets (`Preset`, §5), oldest first. Nothing is
seeded: an empty list is normal.
`notifications` is the stored ntfy configuration (§3). `topic` is a secret the
authenticated apps need for the "Subscribe in ntfy" link/QR; the hub never logs it.
`projectDefs` is the stored project definitions (`ProjectDef`, §5) in their
stored order. `projects` is the same definitions' names, kept for older apps.
`models` is the current catalog (§5); `defaultModel` is the hub-wide default
catalog id (`claude/opus` unless changed with `defaults.set`).
`terms` lists the PTY terminals alive on the hub (§5, `TermInfo`); terminals
are per-process and are not restored after a hub restart.
`drafts` holds every **non-empty** unsent composer text, keyed by session id
(v9 §1). `queues` holds every **non-empty** prompt queue in due order (v9 §2).
`pins` holds every chat's **non-empty** pin list, oldest first (v10 §13).
If the token is wrong, the hub sends `{t:"err", code:"auth"}` and closes the socket.

## 2. App → hub
| t | fields | reply |
|---|---|---|
| `sessions.list` | — | `{t:"sessions", sessions, projects:string[], projectDefs:ProjectDef[]}` |
| `session.open` | `id, since?:number, limit?:number, before?:number` | `{t:"history", id, items:HistoryItem[], lastSeq}` when `since` is absent or the hub has a gap (full history from the transcript), then live `event` frames. With `since`, only events after that seq are sent. The app is then **subscribed** to the session. **Paging (v11):** with `limit` (integer 1 to 5000) the `history` frame carries only the newest `limit` chat items, plus `offset` (index of `items[0]` among the chat items) and `total`; `task` items always ride with the newest page. `before` (needs `limit`, an earlier `offset`) returns the `limit` items ending just before it, with `older:true`, no live events and no subscription change. Older hubs ignore both fields and send the full history without `offset`; apps treat a missing `offset` as "nothing older". |
| `session.close` | `id` | `ok`. Unsubscribes this app; the session keeps running. |
| `session.new` | `cwd, model, text, images?, permissionMode?, project?, at?` | `ok{id}`. The app is subscribed, then receives every event of the new session since seq 0 (including its own first `user` event). `project` is optional: `""` or a known project name assigns the chat immediately. An unknown name is `err bad_request` and no session is created. `at` (v17-E) queues `text` for that time instead of sending it now: the chat is created idle, no `user` event is emitted, and the prompt fires from the queue like any other. A non-date `at` is `err bad_request` and nothing is created. |
| `session.delete` | `id` | `ok`. Stops a live session if needed, then permanently removes it from the hub: its stored info, events and project assignment. Claude's transcript is **moved to `<dataDir>/trash/`** (file name collision gets a `-<epochms>` suffix), so the chat is recoverable. All apps receive `session.removed`. Unknown `id` → `err not_found`. |
| `session.send` | `id, text, images?` | `ok` |
| `session.resend` | `id, text, images?` | `ok`. v10 §11: edit a sent prompt. If the chat is running or waiting for a permission, the hub interrupts the turn (same path as stop), denies any pending permission, waits for the turn to end (10 s cap), then sends `text` exactly as `session.send` does. Idle/error chats send at once. Queued items stay queued and fire after this new turn. |
| `session.interrupt` | `id` | `ok` |
| `session.stop` | `id` | `ok`. Stops the process; the session becomes `stopped` and can still be resumed. |
| `session.setModel` | `id, model` | `ok` |
| `session.setMode` | `id, mode` | `ok` (`default`, `acceptEdits`, `plan`, `auto`) |
| `session.rename` | `id, title` | `ok` |
| `session.setProject` | `id, project` | `ok`. `project` is `""` (no project) or a name from `projectDefs`; anything else is `err bad_request`, an unknown `id` is `err not_found`. The hub stores the assignment and re-emits `session.updated`. |
| `project.save` | `project:ProjectDef, oldName?:string` | `ok`, then the hub broadcasts `projects` to all apps. With `oldName`, renames an existing project (moving every chat assigned to it); without, creates it or updates a project of the same name. A name clashing with a **different** existing project is `err bad_request`. |
| `project.delete` | `name` | `ok`, then broadcasts `projects`. Deletes the definition and ungroups every chat assigned to it (their `project` becomes `""`). No chat is deleted. Unknown name → `err not_found`. |
| `preset.save` | `name, agentPolicy?, subagents?` | `ok{presetId}`, then broadcasts `presets` to all apps. Saving an existing name overwrites it and keeps its `presetId`; a new name gets a fresh id. Name trimmed must be 1–80 characters, `subagents` must be a `SubagentDef[]` → else `err bad_request`. |
| `preset.delete` | `presetId` | `ok`, then broadcasts `presets`. Unknown id → `err not_found`. |
| `agents.list` | — | `{t:"agents", agents:AgentType[]}`. Agent types discovered in `<configDir>/agents` and `~/.claude/agents` for the active account (first directory wins on a name clash). |
| `permission.reply` | `id, reqId, allow:boolean, always?:boolean, message?, answers?, annotations?` | `ok`. `answers` is `{question: answer}` and `annotations` is `{question: {notes?}}`; both are only valid for `tool == "AskUserQuestion"` (anything else → `err bad_request`), and an allowed AskUserQuestion reply must answer every question (else `err bad_request`). The hub maps the answers into the tool's `updatedInput`. `message` is the deny reason: the Skip default is "The user did not answer; continue with your best judgement." and the plan default is "Keep planning.". |
| `account.switch` | `name, now?:boolean` | `ok`. Hub broadcasts `accounts`. |
| `account.rename` | `name, label` | `ok`. Renames the account's display label and broadcasts `accounts`. Unknown `name` → `err not_found`; `label` trimmed must be 1–40 characters → else `err bad_request`. |
| `account.add` | `provider, name, label` | `ok`. Adds an account under an existing provider; `name` is 1–32 letters/digits/`-`/`_`, `label` 1–40 characters. Unknown provider or duplicate name → `err bad_request`. Hub broadcasts `accounts`. |
| `account.remove` | `name` | `ok`. Removes the account and its stored key; the last account cannot be removed (`err bad_request`), unknown name → `err not_found`. Hub broadcasts `accounts`; if it was the active Claude account, live sessions stop. |
| `account.login` | `name` | `ok`. Only for `claude-subscription` accounts (otherwise `err bad_request`). The hub then sends `{t:"login", name, url?, status}` updates to **all** apps. |
| `provider.save` | `provider:ProviderConfig` | `ok`. Creates or replaces a provider in `hub.json` (an existing `active` account is kept when the frame omits it). Invalid shape → `err bad_request`. Hub broadcasts `models`. |
| `provider.delete` | `id` | `ok`. Removes an unused provider; a provider that still has accounts → `err bad_request`, unknown `id` → `err not_found`. Hub broadcasts `models`. |
| `provider.setActive` | `provider, account` | `ok`. Sets which account of that provider new chats and discovery use (for `claude` this is the same as `account.switch`); the account must belong to the provider (`err bad_request`). Hub broadcasts `accounts` and, if the catalog changes, `models`. |
| `secret.set` | `account, key:string\|null` | `ok`. Stores (or with `null` clears) the API key for an account. The key is **never** echoed: `accounts` carries only `keyHint` (last 4 characters). Unknown account → `err not_found`. |
| `defaults.set` | `model` | `ok`. Sets the hub-wide default model. Legacy names (`opus`, `sonnet`, `haiku`) are migrated to catalog ids; an id not in the catalog → `err model_unavailable`. |
| `notifications.set` | `enabled?:boolean, server?:string, regenerate?:boolean` | `ok`, then the hub broadcasts `{t:"notifications", enabled, server, topic}` to every app. Omitted fields keep their value. `server` must be an http(s) URL; trailing slashes are stripped, anything else → `err bad_request`. A topic (`proteus-` + 32 random lowercase letters/digits) is generated when notifications become enabled without one, or with `regenerate:true`. Settings live in the hub's KV store (not `hub.json`); the topic is never logged. |
| `notifications.test` | — | `ok` after posting one test notification (`Proteus: test notification`). `err bad_request` when notifications are disabled (or no topic exists); `err internal` when the post failed. Neither message contains the topic or the server URL. |
| `appearance.setSlot` | `index:0..4, slot:{color,shift,sat}\|null` | `ok`, then the hub broadcasts `{t:"appearance", slots}`. `index` outside 0..4, a colour that is not `#RRGGBB`, `shift` outside (−180, 180] or `sat` outside [0, 1.25] → `err bad_request`; `null` empties the slot. The hub sets `savedAt`. Slots are shared by every app and workstation of this hub. |
| `draft.set` | `id, text, client?` | `ok`, then the hub broadcasts `{t:"draft", id, text, updatedAt, by}` to **all** apps. `text` is the unsent composer text of that chat (v9 §1), capped at 100 000 characters → else `err bad_request`; an empty `text` deletes the draft. `client` is the app instance id that made the edit (default `""`) and comes back as `by`, so an app can ignore its own echo. Unknown `id` → `err not_found`. The KV form is `{text, updatedAt, by}` under `draft:<id>`. |
| `queue.add` | `id, text, at?` | `ok{qid}`. Adds a prompt to the chat's queue (v9 §2). `text` is 1–100 000 characters, `at` an ISO time to send it at, or absent for "after the current turn". A non-date `at` or bad `text` → `err bad_request`; unknown `id` → `err not_found`. The hub then broadcasts `queue`. |
| `queue.update` | `qid, text?, at?` | `ok`. Changes an item's text and/or its time; `at:null` turns a scheduled item into a plain queued one. Bad text/`at` → `err bad_request`, unknown `qid` → `err not_found`. Broadcasts `queue`. |
| `queue.remove` | `qid` | `ok`. Deletes the item and broadcasts `queue`. Unknown `qid` → `err not_found`. |
| `queue.sendNow` | `qid` | `ok`. If the chat is idle (or stopped, or paused by an error), the item is sent now; if it is running or waiting for a permission, the item becomes the next one (`at` cleared and moved first in line). Broadcasts `queue` (and later the turn's events). Unknown `qid` → `err not_found`. |
| `pin.add` | `id, seq, kind, excerpt, ts?` | `ok{pinId}`, then the hub broadcasts the chat's full `{t:"pins", id, pins}` to every app (v10 §13). `kind` is `user`, `assistant`, `tool` or `group`; `seq` is the item's event seq (for a group, its first tool's); `excerpt` is at most 160 characters (longer → `err bad_request`). `ts` is the item's ISO time, optional and `""` when absent; the app sends what it has. Unknown `id` → `err not_found`. The KV form is an array of `Pin` under `pins:<id>`. |
| `pin.remove` | `id, pinId` | `ok`, then the hub broadcasts `{t:"pins", id, pins}` with the remaining pins (`[]` when none are left). Unknown `id` or `pinId` → `err not_found`. |
| `models.list` | — | `{t:"models", models:ModelInfo[]}` |
| `access.clear` | `account, model` | `ok`. Forgets the learned access denial for one model on one account ("Try anyway"): deletes the record entry for the model id, its `engineModel` and its `resolvedModel`; the hub broadcasts `models` when a record changed. Unknown account → `err not_found`. |
| `config.set` | `fsRoots:FsRoot[]` | `ok`. Replaces the hub's browsable folders (v13 §2.1). Each root needs an id `[a-z0-9-]{1,32}` (unique in the list), a label (trimmed, 1–40 characters) and a `path` that exists and is a directory; a path may be absolute or begin with `~`/`~/` (expanded with the hub's base home when roots are resolved). Anything else → `err bad_request` and nothing changes. The list is saved to `hub.json`, then the hub broadcasts `fs.roots` (§3). |
| `fs.roots` | — | `{t:"fs.roots", rid, roots:FsRoot[]}`. The configured `fsRoots`, one root per project folder (`id:"project:<name>"`, label = project name), then the built-in places and devices, as resolved real paths. Deduplicated by path (the first root of a path wins: configured roots first) and by id (a configured root wins on its id). Groups: `places` (configured roots, `home`, the existing XDG folders as `xdg-desktop`, `xdg-documents`, `xdg-downloads`, `xdg-pictures`, `xdg-music`, `xdg-videos`), `projects` (`project:<name>`) and `devices` (`computer` = `/`, plus one `dev:<mount-point>` per real mounted filesystem); Computer and every device carry `free` and `total` bytes from `statfs`. Icons: `home`, `desktop`, `documents`, `downloads`, `pictures`, `music`, `videos`, `folder`, `computer` and `drive`; other configured roots get `folder`. A root whose folder is gone is omitted. |
| `fs.info` | `root, path` | `{t:"fs.info", rid, path, dir, size, mtime, btime, mode, owner, group, mime, count?}` (v17). Metadata for one path under a workstation root. `path` in the reply is the resolved real path; `mtime`/`btime` are ISO (`btime` is `null` when the filesystem records none); `mode` is the permission bits as `rw-r--r--` (no leading type character); `owner`/`group` are the passwd/group names (the numeric id when unknown); `mime` is `inode/directory` for a folder. Folders also carry `count` (capped at 10 000). Same realpath scope and forbidden list as `fs.list`; a missing path → `err not_found`. |
| `fs.space` | `root, path?` | `{t:"fs.space", rid, free, total}` (v17). Free (available) and total bytes of the filesystem holding `path`, or the root itself when `path` is absent. Same scope and forbidden list as `fs.list`. |
| `fs.mkdir` | `root, path` | `{t:"fs.done", rid, op:"mkdir", root, path}` (v17 §4). Creates **one** folder at `path` (not recursive): the parent must already exist and resolve inside the root, and `path` must name one folder (no trailing `/`, and the last segment is never empty, `.` or `..`) → else `err bad_request`. The reply `path` is the new folder's resolved real path. An existing target → `err exists`; a missing parent or root → `err not_found`; a parent outside the root, on the forbidden list, or inside `/proc`, `/sys`, `/dev` → `err forbidden`, and so is a folder named `.git` or `node_modules`. The new path is realpath-checked after creation and removed again if it landed outside the root. |
| `fs.rename` | `root, path, name` | `{t:"fs.done", rid, op:"rename", root, path}` (v17 §4). Renames `path` to `name` in its existing parent folder: `name` is a bare base name, so it never contains `/` and is never `.`, `..` or empty → else `err bad_request`. A missing source or root → `err not_found`; a source outside the root, on the forbidden list, a root itself, or a `name` of `.git`/`node_modules` → `err forbidden`; a name already taken → `err exists` (a rename never overwrites). The reply `path` is the **new** resolved real path. |
| `fs.delete` | `root, path` | `{t:"fs.done", rid, op:"delete", root, path}` (v17 §4). Deletes a file or a folder **recursively**. A root itself is never deleted, and neither is a path outside the root, on the forbidden list, a `.git`/`node_modules` folder, or anything in `/proc`, `/sys`, `/dev` → `err forbidden`. A symlink is unlinked as itself, never followed: what it points at survives. A missing path or root → `err not_found`. The reply `path` is the removed entry's resolved real path. |
| `fs.dirs` | `path` | `{t:"dirs", path, dirs:string[]}`. `path` in the reply is the resolved real path; subfolders only, for the folder picker. |
| `fs.list` | `id` **or** `root`, `path` | `{t:"fs.listing", rid, path, entries:FsEntry[], skipped?:true}`. Lists one folder: of the chat's tree with `id` (v10 §7), or under a workstation root with `root` (v13 §2.1). Exactly one of `id` and `root` is required (else `err bad_request`); a relative `path` joins the chat's `cwd` (with `id`) or the root (with `root`). `path` in the reply is the resolved real path. Directories come first, then files, each by name; hidden names (starting with `.`) are included with `hidden:true`; file entries carry `size` and `mtime`. Folder entries also carry `count` (v17): the number of entries from one `readdir`, capped at 10 000, omitted when unreadable. Listing `.git`, `node_modules`, `/proc`, `/sys` or `/dev` itself returns `entries:[]` and `skipped:true`. |
| `fs.read` | `id` **or** `root`, `path, maxBytes?` | `{t:"fs.file", rid, path, size, mtime, text?, binary, truncated, image?}`. Reads one file, read-only, with the same `id`/`root` scope as `fs.list`. Text is UTF-8 capped at 1 MB; `maxBytes` (a positive integer, default 262144) caps the returned text and is itself capped at 1 MB. `truncated` says the file is longer. A binary file (NUL in the first 8 KB, or invalid UTF-8) returns `binary:true` and no `text`. A png/jpg/gif/webp image up to 5 MB returns `image:<base64>` instead. |
| `fs.find` | `root, query, limit?, path?` | `{t:"fs.found", rid, root, entries:FsEntry[], truncated}`. Case-insensitive substring match on file and folder names under `root`, breadth-first (v13 §2.1). `path` (v17-B3) narrows the walk to that folder inside the root — the app's "This folder" sends the open folder, "Everywhere" omits it; a folder outside the root or on the forbidden list → `err forbidden`. `.git`, `node_modules`, `target`, `build*` and hidden directories are neither walked nor reported; hidden files still match. `limit` defaults to 200, is capped at 1000 and must be a positive integer (else `err bad_request`). The walk stops after 20 000 entries or 3 s and sets `truncated`; reaching `limit` also sets it. One walk per root: a new `fs.find` on the same root cancels that root's previous walk, which then sends nothing; finds on different roots run side by side (v17-B3 — one generation per client used to cancel every other root's walk). Every entry carries its absolute real `path` (`FsEntry.path`), which the app needs to open or download it. Unknown `root` → `err not_found`; a forbidden root → `err forbidden`. |
| `fs.download` | `root, path` | `{t:"fs.stat", rid, root, path, size, mtime, mime}`, then `{t:"fs.chunk", rid, seq, data:<base64>, last}` frames of ≤ 256 KB (v13 §2.1). `seq` starts at 0; `last:true` marks the final chunk; an empty file is one empty chunk. Same realpath scope and forbidden list as `fs.list`. A missing file → `err not_found`, a folder → `err bad_request`. The hub awaits every chunk before reading the next (back-pressure). |
| `term.open` | `cwd?, cols:int>0, rows:int>0, plain?:boolean` | `{t:"term.opened", term:TermInfo}`, and the hub broadcasts `terms`. `cwd` is used only if it is an existing folder; otherwise the shell starts in the hub user's home folder. `plain` defaults to `true`: the terminal starts in Proteus style, without the shell's startup greeting (see §3 terminals note). `plain:false` starts an untouched login shell, for the app's own-setup mode. A missing/non-integer/non-positive size, a non-string `cwd`, or a non-boolean `plain` → `err bad_request`. |
| `term.attach` | `id` | `ok`, then `{t:"term.output", id, data, replay:true}` whose `data` is up to the last 512 KB of output. The app is **subscribed** to that terminal's output. Unknown id → `err not_found`. |
| `term.input` | `id, data:base64` | No reply on success; `data` is decoded and written to the shell as raw bytes. Unknown id → `err not_found`. |
| `term.resize` | `id, cols:int>0, rows:int>0` | No reply on success. Unknown id → `err not_found`; an invalid size → `err bad_request`. |
| `term.close` | `id` | `ok`. Sends the shell SIGHUP (SIGKILL if it is still alive after 3 s). Unknown id → `err not_found`. Every app then receives `term.exit`. |
| `term.list` | — | `{t:"terms", terms:TermInfo[]}` |
| `ping` | — | `pong` |

Images: `{mediaType:"image/png"|"image/jpeg"|..., data:<base64>}`.

`fs.list` and `fs.read` are read-only and scoped to one chat or one
workstation root. With `id`, the path must resolve through `realpath` inside
that chat's `cwd` or its project's folder (`ProjectDef.cwd`). With `root`, the
scope is that root's resolved real path. Anything else, including a symlink
that escapes, is `err forbidden`; an unknown chat or root is `err not_found`.
`fs.find` and `fs.download` use the same forbidden list; the forbidden root
itself is `err forbidden`. Even inside the scope, the hub's own config and
secrets files, `~/.config/proteus/`, `~/.ssh/`, `~/.config/deepseek-proxy/`,
`~/.gnupg/` and any `.credentials.json` are `err forbidden`, and `fs.list`
omits them. v17: `/proc`, `/sys` and `/dev` (and anything under them) list as
folders but return `skipped:true`, and `fs.read`/`fs.download` refuse them
with `err forbidden`; `fs.find` under `computer` does not walk them or another
device's mount point (and a find rooted inside one returns nothing).

The v17 §4 writes (`fs.mkdir`, `fs.rename`, `fs.delete`) take one `root` only
(never a chat `id`), resolve `path` by the same rules as `fs.list`, and refuse
everything the read side refuses: the same realpath scope and the same
forbidden list. They also respect the read side's skip list: `.git` and
`node_modules` are never created, renamed to, or deleted, and nothing is
written inside `/proc`, `/sys` or `/dev`. All three answer with one frame,
`fs.done`, whose `path` is the resolved real path after the operation.

## 3. Hub → app (push)
| t | when |
|---|---|
| `session.updated` | Any SessionInfo change (status, title, model, account). Sent to **all** apps. |
| `event` | `{id, seq, ts, kind, data}`. Sent to apps subscribed to that session. See §4. |
| `permission.request` | `{id, reqId, tool, input, title?, description?}`. Also sent to all apps, so a notification can show it. |
| `permission.resolved` | `{id, reqId}`. Another app answered, or the request was cancelled. |
| `accounts` | `{accounts, active}`. Usage or the active account changed. |
| `appearance` | `{slots:AppearanceSlots}`. A custom colour slot was saved or cleared (v7). Sent to **all** apps. |
| `draft` | `{id, text, updatedAt, by}`. The unsent composer text of a chat changed (v9 §1). Sent to **all** apps: after `draft.set`, and with `text:""`, `by:""` when a `session.send` succeeded or the hub cleared it. An app ignores a `draft` whose `by` is its own instance id. |
| `queue` | `{id, items:[{qid, text, at, createdAt}]}`. A chat's prompt queue changed: add, update, remove, a fired item, or chat deletion (v9 §2). Items are in due order (`at`, else `createdAt`, ascending). Sent to **all** apps. |
| `pins` | `{id, pins:Pin[]}`. A chat's pins changed (`pin.add`, `pin.remove`, or chat deletion, where `pins` is `[]`). Oldest first. Sent to **all** apps. |
| `notifications` | `{enabled, server, topic}`. The ntfy configuration changed (`notifications.set`). Sent to **all** apps. |
| `models` | `{models:ModelInfo[]}`. The model catalog changed (discovery, provider save/delete, account login or key). |
| `projects` | `{projectDefs:ProjectDef[], projects:string[]}`. Sent to **all** apps after `project.save` / `project.delete`. |
| `fs.roots` | `{roots:FsRoot[]}`. The browsable roots changed (`config.set`); sent to **all** apps right after the requester's `ok`. |
| `presets` | `{presets:Preset[]}`. Sent to **all** apps after `preset.save` / `preset.delete`. Oldest first. |
| `session.removed` | `{id}`. Sent to **all** apps after `session.delete` (the requester's `ok` is sent first). Apps drop the chat, any subscription and its pending-permission state. |
| `terms` | `{terms:TermInfo[]}`. Sent to **all** apps when a terminal opens, exits, or changes its OSC 0/2 title. |
| `term.output` | `{id, data:base64, replay?:true}`. Raw terminal output, sent **only** to apps that sent `term.attach` for `id`. `replay:true` marks the one buffer replay sent on attach; later frames carry no `replay` field. Output is coalesced to at most 60 frames/s per terminal. |
| `term.exit` | `{id, code:number}`. Sent to **all** apps when the shell exits (including after `term.close`); the terminal no longer exists. |

## 4. Event kinds (`event.kind`)
| kind | data |
|---|---|
| `user` | `{text, images?:number}`. A user message: sent by an app, or by a terminal. |
| `text_delta` | `{text}`. Streaming text of the current assistant block. |
| `thinking_delta` | `{text}` |
| `assistant` | `{blocks:Block[]}`. The final assistant message; replaces the deltas shown so far. |
| `tool_result` | `{toolUseId, isError, text}`. `text` is truncated to 4000 characters. |
| `status` | `{status}`. Mirrors SessionInfo.status. |
| `result` | `{ok, costUsd?, durationMs, error?, apiStatus?}`. End of a turn. |
| `error` | `{message, code?}`. `code` is the SDK error kind, e.g. `rate_limit` when the account's usage limit is reached; apps should show the message and suggest switching account. |
| `notice` | `{text}` for hub-side messages, e.g. "moved to account B". A background-task notice (v10 §8) is `{kind:"task"\|"reminder", summary, status?}`: a user-role message that consisted only of `<task-notification>` / `<system-reminder>` blocks. `summary` is one line (capped at 300 chars); `status` is the task notification's `<status>` when present. A sub-agent hand-back (v10 §8.1) is `{kind:"agent", from, summary, report?}`: a user-role message made only of `<agent-message>` / `<teammate-message>` blocks, optionally preceded by "Another Claude session sent a message:". `from` is the block's `from` attribute; `summary` is the first non-empty report line (capped at 120 chars); `report` is the full report for expand-in-place. Only a prompt a person typed is a `user` event: history checks the entry's `isMeta`/`origin`/`promptSource` markers, and live user-role messages are notices only (the manager's prompt echo is the live `user` event). Mixed typed-prompt messages keep their real user text and drop the blocks; any other injected text is dropped. Apps ignore unknown notice kinds. |
| `task` | `TaskData` (§5). A sub-agent task's **full** state, sent on `task_started`, `task_progress` (at most once per second per task) and `task_notification`. `status` becomes `completed`/`failed` from the notification, or `stopped` when the session's process ends with the task still running. History for sessions with no logged task events derives completed tasks from Claude's transcript; missing usage numbers stay absent. |

`pins` is not an event kind: pin changes are broadcast as the `pins` push frame
(§3) and carried in `welcome.pins` (§1). Pins are deleted with their chat.

`Block` = `{type:"text", text}` · `{type:"thinking", text}` ·
`{type:"tool_use", id, name, input}`.
Events from a subagent carry `data.parent` (the parent tool_use id), so apps
can nest them under that tool call.

`seq` increases by 1 per event within a session and is never reused. Apps
**ignore any event whose seq is not greater than the last seq they hold** (the
hub may send an event twice around subscribe/replay). History items carry no
seq; the `history` frame's `lastSeq` is the seq to continue from. An app
that reconnects sends `session.open{id, since:lastSeq}`. If the hub no longer
has those events, it sends a full `history` instead. A history item's `ts` is
its transcript line's timestamp; it is empty when the line has none (older
transcripts), and apps then show no time.

## 5. Shared shapes
```
Account     {name, label, email?, provider, kind, loggedIn, keyHint?, usage?: {fiveHour?:Window, sevenDay?:Window, windows?:Window[], status?, updatedAt?}}
Window      {key?:string, label?:string, utilization:number /*0..1*/, resetsAt?:string /*ISO*/}
SessionInfo {id, title, cwd, project, model, account, status, mode, updatedAt,
             live:boolean, agentsRunning:number, queued:number, commands:string[]}
project     string   // project name from projectDefs; "" = no project
status      "idle" | "running" | "waiting" | "error" | "stopped"
HistoryItem = {ts, kind, data}   // event without id/seq; built from Claude's transcript

ProjectDef  {name, cwd?, defaultModel?, instructions?, agentPolicy?, subagents:SubagentDef[]}
SubagentDef {name, when, model:"inherit"|"top"|"mid"|"fast"|ModelId, tools:"all"|"read-only", prompt?}
Preset      {presetId, name, agentPolicy, subagents:SubagentDef[]}  // v10 §15.4
AgentType   {name, description, model?, source:"user"|"project"}

ProviderConfig {id, kind:"claude-subscription"|"anthropic-api"|"anthropic-compatible",
                label, baseUrl?, sanitize?:"deepseek", models?:ProviderModelConfig[], active?:string}
ProviderModelConfig {key, engineModel, label, tier?:"top"|"mid"|"fast"}
ModelInfo   {id, label, description?, provider, engine:"claude-code", engineModel,
             resolvedModel?, tier?, available, unavailableReason?:"credits"|"unavailable", pinned?}
ModelId     string   // "<provider>/<key>", e.g. "claude/opus", "deepseek/flash"

TaskData    {taskId, toolUseId?, parentTaskId?, agent, description, model?,
             status:"running"|"completed"|"failed"|"stopped",
             startedAt, endedAt?, tokens?, toolUses?, durationMs?,
             lastTool?, summary?}
TermInfo    {id, title, cwd, pid, createdAt, alive}

AppearanceSlots = Array<AppearanceSlot|null>   // exactly 5 entries; null = empty
AppearanceSlot  {color:"#RRGGBB", shift:number /*(-180,180]*/,
                 sat:number /*[0,1.25]*/, savedAt:string /*ISO*/}

DraftWire   {text, updatedAt}            // welcome.drafts entry; non-empty only
QueueItem   {qid, text, at:string|null, createdAt}   // due order in queue frames
Pin         {pinId, seq:number, kind:"user"|"assistant"|"tool"|"group",
             excerpt, ts, pinnedAt}      // ts "" when the item has no time
FsRoot      {id, label, path, group:"places"|"projects"|"devices", icon:string,
             free?:number, total?:number}   // path is a resolved real path;
                                            // devices carry free/total bytes
FsEntry     {name, dir:boolean, size:number, mtime:string /*ISO*/, hidden?:true,
             path?:string, count?:number}   // folders: entry count, cap 10 000
FsInfo      {path, dir:boolean, size:number, mtime:string /*ISO*/,
             btime:string|null /*ISO*/, mode:string /*rw-r--r--*/,
             owner:string, group:string, mime:string, count?:number}
FsFile      {size:number, mtime:string /*ISO*/, binary:boolean, truncated:boolean,
             text?:string, image?:string /*base64, no data: prefix*/}
```
`shift` is the hue shift from the clay accent `#D97757`; `sat` scales the
saturation of the dither tones, flat background, accent and hand/mark sprites.
The picked colour's brightness is not stored (each tone keeps its designed
brightness). `savedAt` is set by the hub. The selected palette (`blue` or
`custom:<n>`) is per device, not part of these slots.

`SessionInfo.agentsRunning` is the number of sub-agent tasks currently running
in that session (0 when stopped, idle, or for sessions imported from older hub
versions). It changes trigger `session.updated`.

`SessionInfo.queued` is the number of items in that chat's prompt queue, so a
chat list can show a chip; it changes trigger `session.updated`.
`SessionInfo.commands` lists the slash commands the Claude engine advertised in
its `system/init` message (the user's own commands and skills included). It is
persisted with the session and defaults to `[]`. A prompt that starts with one
of them is sent unchanged; Claude Code handles it.

### Drafts and queue (v9)
A draft is the text an app has typed in a chat but not sent. It lives in the
hub KV as `draft:<sessionId>` = `{text, updatedAt, by}`, is capped at 100 000
characters, and is deleted by an empty `draft.set`, by a successful
`session.send`, and by `session.delete`. Every `draft.set` is answered with
`ok` and then broadcast as `draft` to **all** apps; `welcome.drafts` carries the
non-empty drafts so a newly opened app starts with them.

The prompt queue is a sqlite table that survives hub restarts. An item is
**due** when `at` is null or `at <= now`, ordered by `at` (null counts as
`createdAt`). The hub sends the first due item only when the chat is idle or
stopped (not running, not waiting for a permission, and not paused by an
error), using exactly the `session.send` path with the chat's current model and
mode; a stopped chat therefore resumes. Only one item fires per turn: the next
waits for the status to return to `idle`. A chat whose status is `error` does
not fire until the user sends something or uses `queue.sendNow`. The hub keeps
one timer to the nearest future `at` (capped at 24 days, then re-armed) plus a
30-second sweep; overdue items fire as soon as the hub starts. Deleting a chat
deletes its items. `welcome.queues` carries the non-empty queues at handshake.

`TaskData.agent` is the subagent type, or `task_type` for other local tasks,
or `"agent"` when neither is known. `model` is a catalog id resolved from the
Task/Agent tool input's `model`, else from the sub-agent definition, and is
absent when neither is known. `tokens`/`toolUses`/`durationMs` are cumulative
for the task; a live task always carries them (0 until the first usage report),
while a task derived from an old transcript omits a number the transcript never
recorded. `summary` is capped at 300 characters.

Terminals are PTY processes on the hub's own computer, not in the app. Each
uses the hub user's login shell (`$SHELL -l`, falling back to the passwd
shell, then `/bin/bash -l`) and starts in `cwd` when it is an existing
folder, else the home folder. Plain terminals (the default) start in
Proteus style: for `fish`, the hub adds `-C 'function fish_greeting; end'`
so the greeting does not print; other shells are left untouched.
`plain:false` runs the login shell with no additions. Every terminal's
environment carries `PROTEUS_TERMINAL=1` and `TERM_PROGRAM=proteus`, so a
shell config can skip its startup output itself. All
`term.input`/`term.output` data is base64 of raw bytes, so non-UTF-8 output
survives the round trip. Output also feeds a 512 KB ring buffer per terminal
for `term.attach` replay, and frames are coalesced to at most 60 per second per
terminal. Titles come from OSC 0/2 sequences emitted by the program in the
terminal; the default is the starting folder's name. Terminals belong to the
hub process: they are not persisted, and a hub shutdown sends them all SIGHUP.

`Account.kind` is the provider kind. API-key accounts (`anthropic-api`,
`anthropic-compatible`) have `loggedIn = key present` and `keyHint` = the last
four characters of the stored key; the key itself never leaves the hub.

`ModelInfo.available` means the provider has a usable account/key **and** the
provider's active account can use the model. When a turn fails because the
account needs usage credits or the API says the model is not available to it,
the hub learns that for the account. The affected entry (and the alias's
resolved model) is then `available:false` with `unavailableReason` (`credits` |
`unavailable`) until a successful turn clears it, the record is 24 hours old, or
the account logs in / becomes active. `resolvedModel` is the fixed model id a
discovery row resolves to, when known.
`engineModel` is what the Claude Code engine receives; the loopback router
selects the upstream provider from it. Apps should treat an unavailable entry
as a menu item that is shown disabled rather than a normal choice, and offer
`access.clear` as a "Try anyway" action so it can be retried before the record
expires; an explicit
`session.new` / `session.setModel` on it is still accepted (credits may have
been bought). `session.new` and `session.setModel`
accept a catalog id; the legacy bare names `opus`/`sonnet`/`haiku` and
`deepseek-flash` are migrated to their catalog ids. An id not in the catalog is
`err model_unavailable`.

`SubagentDef.model` tiers resolve at query start: the chat's own provider's
model of that tier, else the default provider's, else `inherit`.

### Usage
`Window.utilization` is always a fraction from 0 to 1. The OAuth usage endpoint
reports percentages (0..100); the hub divides by 100 and never synthesises a
window: a missing `fiveHour`/`sevenDay` means the value is unknown, not zero.
`status`/`updatedAt` are recorded even when a window is unknown. `usage` is
refreshed from the endpoint at startup, every 5 minutes, and about 15 seconds
after a turn ends (debounced per account).

`usage.windows` lists every limit the endpoint reports, in display order
(session, the all-models week, then the remainder in endpoint order). Each
entry has `key` (the endpoint's name, e.g. `five_hour`, `seven_day_opus`) and a
display `label` (e.g. `Session`, `Week (Opus)`). Entries that are not limits,
such as `seven_day_overage_included`, are omitted. Older hubs send no
`windows`; apps keep using `fiveHour`/`sevenDay`, which the hub still fills
(the same windows, also carrying `key`/`label`). When `windows` is present an
app should prefer it.

### Projects
Project definitions live in the hub's KV store, not in `hub.json`. On the first
v4 start the hub migrates any `config.projects` entries (name, first path as
`cwd`, no subagents) into `projectDefs` once, freezing each existing chat's old
folder-prefix result as an explicit assignment. After that, `config.projects`
is ignored: a chat belongs to a project only via an explicit assignment
(`session.new{project}` / `session.setProject`), which survives restarts.

Project options apply to a chat's Claude process **when its next query starts**:
the hub passes new agent types for subagents not already installed, plus
`instructions`/`agentPolicy`/subagents appended to the `claude_code` system
prompt. Changing a project therefore affects a chat that is already running only
after it is stopped (or its process ends) and resumed.

