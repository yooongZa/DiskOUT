<div align="center">

<img src="DiskOUT-eject-transparent.png" width="180" alt="DiskOUT">

# DiskOUT

[한국어](README.md) · **English** · [日本語](README.ja.md) · [简体中文](README.zh-Hans.md)

### Introducing DiskOUT — a free Mac utility.

**한국어 · English · 日本語 · 中文 (简体)** · Auto-eject on sleep · Apple Silicon native

<br>

[![Download Latest](https://img.shields.io/github/v/release/yooongZa/DiskOUT?style=for-the-badge&label=Download&color=007AFF&logo=apple)](https://github.com/yooongZa/DiskOUT/releases/latest)

![macOS](https://img.shields.io/badge/macOS-13%2B-lightgrey?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-native-A855F7)
![Languages](https://img.shields.io/badge/i18n-4_languages-3B82F6)
![Developer ID](https://img.shields.io/badge/Developer_ID-signed-22C55E)
![Notarized](https://img.shields.io/badge/Apple-notarized-22C55E)

[Download](https://github.com/yooongZa/DiskOUT/releases/latest) ·
[Changelog](https://github.com/yooongZa/DiskOUT/releases) ·
[Issues / Feedback](https://github.com/yooongZa/DiskOUT/issues) ·
[Terms](TERMS.md) · [Refund Policy](REFUND_POLICY.md) · [Privacy](PRIVACY.md)

</div>

---

<!-- Demo GIF slot: add demo.gif to the repo root, then delete this line and the closing comment to activate.
<div align="center">

<img src="demo.gif" width="700" alt="DiskOUT safely ejects external drives when the lid closes and remounts them when it opens">

</div>
-->

> Mac is perfect — except for the *"Disk Not Ejected Properly"* notification.

## You do nothing. The disk ejects properly. Perfectly.

Now close the lid, unplug, bag — and go.

Apple's SSD prices are insane. And they're not even upgradeable. You get by with external drives, but those *"Disk Not Ejected Properly"* notifications are exhausting. With **DiskOUT**, you don't have to see them anymore.

---

## How?

### 1️⃣ The moment your lid closes, every external safely ejects.

Close → eject. Open → remount.
Configured idle sleep → eject. Wake → remount.

### 2️⃣ Eject 10 externals at once.

One shortcut, or one right-click on the menu bar icon — all of them, gone.

### 3️⃣ See how many drives are connected, at a glance.

The menu bar shows the count as a number.
Core features and the existing numeric menu-bar display remain free. Optional Premium is a USD 4.99 one-time purchase that turns counts 0–12 into cute six-frame animated characters, while keeping a smaller count on the right. Reduce Motion shows a still frame.

---

## Designed to be safe

|  |  |
|---|---|
| **Time Machine auto-protect** | TM backup disks are automatically excluded from auto-eject — no accidental backup interruption |
| **Ignores DMG / disk images** | Mounted disk images don't appear in the menu and aren't auto-ejected |
| **Prevents improper-eject warnings** | Sleep eject tries a normal unmount first. Disconnect after the clean callback; unplugging before completion or after failure can still trigger a warning |
| **Per-disk opt-out** | Exclude specific disks from auto-eject individually. Volume UUID-based, so it survives cable/port changes |
| **No ads · billing data separated** | Disk names and file paths are never sent to the billing server. The Paddle-backed server is contacted only to purchase, verify or transfer Premium, or view purchase details; the app trusts only a signed entitlement |
| **Developer ID + Apple notarized** | Passes Gatekeeper — no "unidentified developer" warning, just opens |
| **Gentle auto-update** | A small red dot in the menu bar + an item in the menu announces new versions. No modal pop-ups. Installed only after EdDSA + Apple Code Signing double verification |

---

## Download

<div align="center">

### [Get the latest release →](https://github.com/yooongZa/DiskOUT/releases/latest)

`DiskOUT-X.Y.Z.dmg` · ~3MB · Apple Silicon only

</div>

### Install (30 seconds)

1. Double-click the DMG → drag DiskOUT to **Applications**
2. On first launch, macOS asks once → click **Open**
3. A number appears in your menu bar (`0` if no externals)

### Requirements

- macOS 13 (Ventura) or later
- Apple Silicon (M1 / M2 / M3 / M4)

---

## Usage

| Action | How |
|---|---|
| Eject one drive | Menu bar icon → click drive name |
| Eject all | Menu "Eject all" or <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| Quick eject all | **Right-click** the menu bar icon |
| Eject + Sleep | Menu "Eject and Sleep" — sleep only starts if all eject succeed |
| Mount unmounted externals | Click the bottom menu section or <kbd>⌃</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| Mount + open in Finder | <kbd>⌘</kbd>+click an unmounted drive |
| Settings | Menu "Settings…" or <kbd>⌘</kbd><kbd>,</kbd> |

### Auto-launch at login

Enable **“Launch at login”** in Settings → General. If macOS asks for additional approval, allow it once in System Settings → General → Login Items.

---

## FAQ

<details>
<summary><b>Why isn't it in the App Store?</b></summary>

Mount/eject operations are heavily restricted in the sandbox environment. Stability would suffer, so we went with direct Developer ID distribution. Apple notarization means Gatekeeper still recognizes it as a trusted app.

</details>

<details>
<summary><b>Is it safe? Any risk of data loss?</b></summary>

Manual eject uses the standard `diskutil eject` path (the same as Finder's "Eject"). DiskOUT-managed eject paths always try a normal unmount first. Eject and Sleep and lid close allow one force attempt only after an explicit busy response and only when the setting permits it; idle/display sleep never forces. System sleep classified as active or unknown passes through untouched.

If even force unmount fails, the disk is left alone — we won't risk data corruption with a hard eject.

</details>

<details>
<summary><b>Is it free?</b></summary>

Yes. Eject, mount, sleep automation, and the existing numeric menu-bar display remain free. Optional Premium animated menu-bar characters cost USD 4.99 once; development builds hide the purchase menu until production billing is configured.

</details>

<details>
<summary><b>Can I move Premium to a new Mac?</b></summary>

Yes. After purchase, open Settings → Premium, choose `Copy Recovery Code…`, and save that code, then use it to transfer Premium to a new Mac. The old Mac loses access on its next online check. If the server cannot be reached, the last verified access remains available for up to 30 days.

</details>

<details>
<summary><b>Can I download without a GitHub account?</b></summary>

Yes. `yooongZa/DiskOUT` is a public repository, and the DMG on GitHub Releases is anonymously downloadable. No GitHub sign-up or login required.

</details>

<details>
<summary><b>Does it work on Intel Macs?</b></summary>

Current builds are Apple Silicon only. No Intel builds planned.

</details>

<details>
<summary><b>I'm still seeing "improperly ejected" warnings</b></summary>

DiskOUT's sleep eject tries a normal unmount first, so this notification usually doesn't appear. When it does, common causes:

- **An app is holding the disk → normal unmount fails**: one force attempt is allowed only when **Allow Force Unmount** is on, the callback reports busy, and the path is manual eject, Eject and Sleep, or lid close. Idle/display sleep never forces, and system sleep classified as active or unknown passes through untouched
- **macOS started ejecting first**: another system component beat us to it before sleep

Fix: quit the app holding the external before sleeping, or turn **Allow Force Unmount** off in Settings.

</details>

---

## Known limitations

- **Clamshell mode (external monitor + power + lid closed)**: lid-close auto-eject starts from the raw lid signal even when macOS stays awake. Turn off lid-close auto-eject if you intend to keep working in clamshell mode.
- **Sleep-origin attribution**: public macOS IOKit notifications do not identify the exact requester. DiskOUT passes through requests with no preceding idle signal or lid-close signal in the last 15 seconds. A rare direct request overlapping those signals may be classified as idle or lid sleep.
- **Busy drives**: Eject and Sleep and lid close may try one force unmount after an explicit busy response when the setting allows it, so work still in progress can be interrupted. Idle/display sleep never forces, and system sleep classified as active or unknown is untouched.
- **Cable disconnected before clean completion**: unplugging before the clean callback or after an eject failure can still produce the macOS improper-eject warning. Disconnect only after success is confirmed.
- **Remount reliability**: Only disks that DiskOUT auto-ejected are remounted on wake. Physically removed disks can't be remounted by software.

See the [release notes](https://github.com/yooongZa/DiskOUT/releases) for technical details.

---

## All features

<details>
<summary>Expand the feature matrix</summary>

| Feature | Description |
|---|---|
| Menu bar dropdown | Lists connected externals. Stale cache shown immediately, then background-refreshed when complete. On refresh failure, the previous cache stays + a failure row is shown. **DA event-driven inventory is the primary source** → menu stays responsive even when `storagekitd` is blocked (e.g. by SD card insertion) |
| **Menu bar icon = ⏏ + mount count** | An eject glyph (⏏) next to the number of mounted external *devices* — instantly identifiable among other status items, and monospaced digits keep the width stable as the count changes. With 0 drives, only the glyph shows (no uninformative "0"). Multi-partition / RAID / APFS synthesized volumes count as 1. Event-driven auto-update from `DAInventory` changes (no polling). Temporary glyphs (↻ · ✓ · ✗) take over during eject progress/results, with a 0.15s crossfade (honors Reduce Motion) |
| **Read/write activity indicator** | When read or write I/O is active on an external, a small systemBlue `●` appears next to the menu bar number + a "Reading / Writing — don't disconnect" tooltip (color-distinct from the red update dot). In the menu, the blue `●` appears **only next to the busy disk** — and the tooltip distinguishes reading / writing / both. Polls physical-disk I/O counters (IORegistry) every 1.5 s; volume→physical mapping via parent-walk handles RAID / APFS-synthesized / direct uniformly. Reads use a higher threshold to avoid background-indexing false positives. Runs only while externals are present (battery) |
| **Disk capacity / usage** | Each disk's menu item shows *free · usage* on a second line — e.g. `2.9 TB free · 40% used`. Read via `URLResourceValues` on menu open (no process spawn) |
| Individual eject | Click drive name |
| **Confirm eject while writing** | Manually ejecting a disk or choosing **Eject and Sleep** while a disk is being written shows a warning with Cancel as the default. Lid-close handling can still force once after a busy response; idle/display sleep never forces |
| **Quit blocker & retry** | On eject failure, if a *quittable regular app* is holding the disk, the notification offers a "Quit apps and retry" button → graceful quit (never `forceTerminate`) → one eject retry. Excludes Finder, system daemons, and itself |
| Eject all | Menu item or shortcut |
| **Eject and Sleep** | Runs whole-disk DA normal requests in parallel, with one Force attempt only after a busy callback and only when **Allow Force Unmount** is enabled. All disks must report clean within 10 seconds before `pmset sleepnow`. Failure, pending, or `pmset` failure cancels sleep; successful and late-clean disks stay ejected for an explicit retry |
| Global hotkey (eject) | Default <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> (IME-independent, physical key code comparison). Preset configurable in settings |
| Global hotkey (mount) | Default <kbd>⌃</kbd><kbd>⌘</kbd><kbd>E</kbd> — bulk mount unmounted externals. Configurable |
| Right-click = eject all | Right-click or ctrl+left-click the menu bar icon. Disable in Settings → Eject Behavior for opt-out (prevents accidental ejection) |
| **Mount unmounted externals** | Auto-shown menu section when candidates exist. Click = mount, <kbd>⌘</kbd>+click = mount + open in Finder |
| **Mount state consistency** | `diskutil list -plist external` snapshot calculates mounted / unmounted together, reducing stale state in the mounted section |
| **Disk-type icons** | `sdcard` icon when `diskutil info -plist` confirms SD card signals, `externaldrive` family otherwise |
| **Eject on idle sleep** | Configure in Settings → Eject Behavior. Only sleep that macOS reports as idle is briefly delayed for whole-disk DA normal. Requests DiskOUT classifies as active or unknown pass through immediately |
| **Eject on display sleep (optional)** | Configure in Settings → Eject Behavior, default OFF. Designed for `pmset sleep=0` setups. Whole-disk DA normal only; successful disks remount when the display wakes |
| **Auto-remount on wake / display wake** | Only disks successfully auto-ejected get remounted. If enumeration fails, treated as user-removed and stays silent |
| **DMG / sparseimage exclusion** | Mounted images filtered via `hdiutil info -plist` (1s timeout) + `diskutil info` fallback. Unmounted candidates excluded by `BusProtocol == "Disk Image"` |
| Eject path | Manual eject uses `diskutil` with **Allow Force Unmount**. Lid/idle/display sleep and “Eject and Sleep” start with whole-disk DA normal; one DA force is allowed only when both the trigger policy and setting permit it and the callback is busy. No force follows timeout, disconnect, or an unknown error |
| Result notifications | **Silent** banner + menu bar icon ✓ / ! / ✗ (unified circle-family symbols). Only negative outcomes (failures, remount failures, sleep eject failures) or background events are kept in Notification Center; user-triggered successes show a brief banner only |
| Parallel eject | `DispatchGroup` for N drives ejected concurrently |
| **Launch at login** | Configure in Settings → General. Uses `SMAppService.mainApp`; `.requiresApproval` appears as a mixed state with a “needs approval” label and a link to System Settings |
| **Settings window** | <kbd>⌘</kbd><kbd>,</kbd> or menu “Settings…”. System Settings-style **toolbar with 6 panes** — General (login · language · error reporting) / Eject Behavior (sleep · display sleep · Music/Photos · force unmount · right-click) / Notifications / Hotkeys / Premium (purchase · restore · status) / About (version · updates · links). Per-pane height transition, every non-obvious option gets a description line |
| **Hotkey conflict auto-fix** | If eject / mount / eject-and-sleep would share the same preset, the conflict is detected + one is auto-moved + alerted |
| **Missing-permission menu hint** | If Accessibility (for global hotkeys) or notification permission is missing, a ⚠ warning row appears at the top of the menu. Click to jump to the relevant System Settings page |
| **Fine-grained notification toggles** | Separate toggles for all / success / failure notifications. All ON by default. If macOS blocks notifications, Settings shows the status and opens the relevant System Settings page |
| **Localization (ko + en + ja + zh-Hans)** | `Localizable.xcstrings` with 172 keys. The app checks the full system language preference list and picks the first supported language, falling back to English only when none match. Settings → General → Language supports system default or an explicit override |
| **Auto-update (Sparkle 2)** | 24h background check. On new version, no modal — just a small systemRed `●` in the menu bar + an "Update to X.Y.Z…" menu item with the same red-dot prefix (gentle reminder). Click → standard Sparkle download/install dialog → auto-restart. EdDSA(Ed25519) + Apple Code Signing double verification. Appcast on GitHub Pages, DMG on GitHub Releases — free hosting |
| **Per-disk auto-eject exclude** | Per-disk toggles in the bottom *"Auto-Eject Excluded Disks"* submenu. Volume UUID-based (survives cable/port changes). Affects auto path only — explicit eject still works |
| **Time Machine auto-protect** | TM backup disks auto-detected (`Backups.backupdb` / `.com.apple.timemachine.donotpresent`) → excluded from auto-eject on first sighting + 1 notification. Menu shows clock icon + a Time Machine badge (macOS 14+; parenthetical on 13) |
| **External library app handling** | Settings → Eject Behavior toggle (default OFF). When ON, Music / Photos quit gracefully before automatic sleep/display eject or **Eject and Sleep**, freeing external-library locks. Only apps that accepted quit are relaunched once in the background after wake; overlapping sleep events do not lose the relaunch record |

</details>

---

## Developer notes

<details>
<summary>Expand build · install · technical notes</summary>

### Tech stack

| Item | Value |
|---|---|
| Bundle ID | `com.yongza.ejectdrives` |
| Hardened Runtime | YES |
| App Sandbox | **NO** (`ENABLE_APP_SANDBOX = NO`) |
| Build system | Xcodegen + xcodebuild |
| Entry point | `main.swift` (explicit `NSApplication.shared.run()`) |
| Disk ops | Manual eject uses `/usr/sbin/diskutil`. Automatic sleep/display sleep and "Eject and Sleep" use whole-disk Disk Arbitration normal first, with at most one policy-authorized busy force |

### Files

```
diskOUT/
├── AppDelegate.swift            # Main logic (diskutil exec, menu cache, sleep/wake handling)
├── LanguageRuntime.swift        # language negotiation, stored-value validation, safe relaunch policy
├── Localizable.xcstrings        # ko + en + ja + zh-Hans translations (Xcode String Catalog, 172 keys)
├── main.swift                   # Explicit entry point (NSApp.run)
├── Info.plist                   # bundle metadata (xcodegen generated)
├── DiskOUT.entitlements         # empty plist. Prevents entitlements pitfalls in project.yml
├── project.yml                  # xcodegen config (sandbox OFF)
├── DiskOUT.xcodeproj/           # Xcode project (regeneratable via xcodegen)
├── Tests/LanguageRuntimePolicyTests.swift # language fallback, stored-value, relaunch state tests
├── CHANGELOG.md
└── README.md
```

### Build

**One-time (project generation)**

```bash
cd ~/Documents/diskOUT
xcodegen generate                  # project.yml → DiskOUT.xcodeproj
```

**Each build**

```bash
cd ~/Documents/diskOUT
BUILD_WORK_DIR="/private/tmp/diskout-build.$(uuidgen)"
xcodebuild -project DiskOUT.xcodeproj -scheme DiskOUT -configuration Release \
  -derivedDataPath "$BUILD_WORK_DIR/DerivedData" build
printf 'Built app: %s\n' "$BUILD_WORK_DIR/DerivedData/Build/Products/Release/DiskOUT.app"
```

Use the rollback-capable procedure below to install it, or open `DiskOUT.xcodeproj` in Xcode → <kbd>⌘</kbd><kbd>R</kbd>.

**Safe install (rollback-capable)**

Recommended when a new build hasn't been fully verified. Backs up the existing `.app` before replacement.

```bash
set -euo pipefail

# 1. Build at an explicit temporary path and verify the bundle ID
cd ~/Documents/diskOUT
INSTALL_WORK_DIR="/private/tmp/diskout-install.$(uuidgen)"
SOURCE_APP="$INSTALL_WORK_DIR/DerivedData/Build/Products/Release/DiskOUT.app"
TARGET_APP="$HOME/Applications/DiskOUT.app"
BACKUP_APP="$HOME/Applications/DiskOUT.app.backup.$(uuidgen)"
xcodebuild -project DiskOUT.xcodeproj -scheme DiskOUT -configuration Release \
  -derivedDataPath "$INSTALL_WORK_DIR/DerivedData" build
[ "$(plutil -extract CFBundleIdentifier raw -o - "$SOURCE_APP/Contents/Info.plist")" = \
  "com.yongza.ejectdrives" ]

# 2. Stop only the exact process and preserve the old app at a unique path
mkdir -p "$HOME/Applications"
pkill -x DiskOUT 2>/dev/null || true
if [ -e "$TARGET_APP" ]; then
  mv "$TARGET_APP" "$BACKUP_APP"
  printf 'Rollback backup: %s\n' "$BACKUP_APP"
else
  BACKUP_APP=""
  printf 'Rollback backup: none (no previous install)\n'
fi

# 3. Install only the verified product and launch it
ditto "$SOURCE_APP" "$TARGET_APP"
xattr -cr "$TARGET_APP"
open "$TARGET_APP"

# 4. Verify
log show --predicate 'subsystem == "com.yongza.ejectdrives"' --info --last 1m
```

If there is a problem, put the exact printed backup path in `BACKUP_APP`. Preserve the failed app at a unique path instead of deleting it, then restore:

```bash
set -euo pipefail
TARGET_APP="$HOME/Applications/DiskOUT.app"
BACKUP_APP="<absolute Rollback backup path printed above>"
FAILED_APP="$HOME/Applications/DiskOUT.app.failed.$(uuidgen)"
[ -d "$BACKUP_APP" ]
pkill -x DiskOUT 2>/dev/null || true
mv "$TARGET_APP" "$FAILED_APP"
mv "$BACKUP_APP" "$TARGET_APP"
open "$TARGET_APP"
printf 'Failed build preserved at: %s\n' "$FAILED_APP"
```

After verification, move unneeded backup or failed apps to the Trash in Finder.

### Where to change options

Most things are in the menu's **Settings…**. Code-only items:

| To change | Location |
|---|---|
| Add a hotkey preset | `SettingsHotkeyPreset` in `AppDelegate.swift` |
| Auto-eject default | `SleepEject.enabled` default value |
| Remount backoff intervals | `delays: [0, 1, 3, 7]` in the `tryRemount(bsd:delays:operationID:)` call |
| Menu text | The strings inside `populateMenu(_:snapshot:isRefreshing:)` |

Key codes use Carbon `Events.h` `kVK_ANSI_*` constants.

### Diagnostic note — `NSStatusBarWindow` height = 0

Early in development, the status item wouldn't appear in the menu bar. Code was 100% correct (NSLog firing, statusItem / button / image all created normally), but nothing was visible. Diagnosis:

```
DIAG: NSApp.windows.count=1
DIAG window: class=NSStatusBarWindow frame=(0.0, 0.0, 32.0, 0.0) visible=true level=25
                                                            ^^^ height=0
```

`NSStatusBarWindow` was created inside the process but never registered with `WindowServer`, or stuck at height=0. Likely a new macOS 26 policy or subtle status-item-system change.

**Workaround** (in `AppDelegate.swift`'s `setupStatusItem`):

```swift
if let win = button.window {
    let thickness = NSStatusBar.system.thickness
    win.setFrame(NSRect(x: 0, y: 0, width: 32, height: thickness),
                 display: true, animate: false)
    win.orderFrontRegardless()
}
```

Without these two lines, the menu bar item doesn't show.

### Diagnostic note — external drive filter

Original filter:

```swift
guard !isInternal, isBrowsable, (isEjectable || isRemovable) else { continue }
```

On macOS 26, some Thunderbolt external SSDs / certain USB drives report `isEjectable=false, isRemovable=false`. Updated:

```swift
guard !isInternal, isBrowsable, isLocal else { continue }
```

`isLocal` guard excludes network mounts only. All external disks pass.

### Other small bits

- **Notch models**: status items can land on the menu bar's left side (next to app menu) — when the right side fills up, items spill over the notch to the left.
- **`com.apple.provenance` xattr**: macOS fileprovider services (iCloud Drive / OneDrive etc.) auto-attach this to files in `~/Documents/`. codesign rejects with "resource fork, Finder information, or similar detritus not allowed". `xattr -cr` clears it but it comes back. **Build in `/tmp/` or another fileprovider-free location for safety.**
- **CGWindowList limitation**: `kCGWindowOwnerName == "DiskOUT"` may return 0 windows even when the menu bar item is visible. `ControlCenter` can draw the status item's view inside its own window, hiding it from external queries.
- **`ProcessRunner` stdout/stderr drain**: `Process` stdout/stderr drained asynchronously via `readabilityHandler`, with leftover data collected after termination. `lsof` 3s timeout, `pmset sleepnow` 5s timeout.

</details>

---

<div align="center">

**DiskOUT** · © 2026 LIMOD · All rights reserved

[Releases](https://github.com/yooongZa/DiskOUT/releases) ·
[Changelog](https://github.com/yooongZa/DiskOUT/releases) ·
[Issues](https://github.com/yooongZa/DiskOUT/issues) ·
[Terms](TERMS.md) · [Refund Policy](REFUND_POLICY.md) · [Privacy](PRIVACY.md)

</div>
