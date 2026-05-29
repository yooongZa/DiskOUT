<div align="center">

<img src="DiskOUT-eject-transparent.png" width="180" alt="DiskOUT">

# DiskOUT

[한국어](README.md) · [English](README.en.md) · **日本語** · [简体中文](README.zh-Hans.md)

### Mac 必須の無料アプリ、DiskOUT のご紹介。

**한국어 · English · 日本語 · 中文 (简体)** · スリープ自動取り出し · Apple Silicon ネイティブ

<br>

[![Download Latest](https://img.shields.io/github/v/release/yooongZa/DiskOUT?style=for-the-badge&label=Download&color=007AFF&logo=apple)](https://github.com/yooongZa/DiskOUT/releases/latest)

![macOS](https://img.shields.io/badge/macOS-14%2B-lightgrey?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-native-A855F7)
![Languages](https://img.shields.io/badge/i18n-4_languages-3B82F6)
![Developer ID](https://img.shields.io/badge/Developer_ID-signed-22C55E)
![Notarized](https://img.shields.io/badge/Apple-notarized-22C55E)

[ダウンロード](https://github.com/yooongZa/DiskOUT/releases/latest) ·
[変更履歴](CHANGELOG.md) ·
[Issue / フィードバック](https://github.com/yooongZa/DiskOUT/issues)

</div>

---

> Mac は完璧です — 「ディスクが正しく取り出されませんでした」通知さえなければ。

## 何もしなくても、ディスクは正しく取り出されます。完璧に。

これからは Mac を閉じて、抜いて、入れて、出かけてください。

Apple の SSD 価格はおかしいです。しかもアップグレード不可。外付けでしのいでいますが、*「Disk Not Ejected Properly」*通知にはうんざり。**DiskOUT** を使えば、もうそんな通知を見る必要はありません。

---

## どうやって?

### 1️⃣ 蓋を閉じる瞬間、すべての外付けが安全に取り出されます。

閉じる → 取り出し、開く → マウント。
スリープ → 取り出し、復帰 → マウント。

### 2️⃣ 10 個の外付けハードも一度に取り出し。

ショートカット 1 回、メニューバー右クリック 1 回で全部取り出し。

### 3️⃣ 外付けディスクが何個か、一目で確認。

メニューバーに接続されたディスクの数が数字で表示されます。

---

## 安心して使えるように

|  |  |
|---|---|
| **Time Machine 自動保護** | TM バックアップディスクは自動取り出しから自動除外 — うっかりバックアップを切断する事故を防止 |
| **DMG · ディスクイメージ無視** | マウント済みディスクイメージはメニューに出ず、自動取り出し対象でもない |
| **「取り出し失敗」通知なし** | スリープ取り出しは正常 unmount(マウント解除) を先に試す — macOS の「improperly ejected」通知が出ない |
| **ディスク別オプトアウト** | 自動取り出しから除外したいディスクだけ個別にトグル。Volume UUID 基準でケーブル / ポートが変わっても維持 |
| **広告 · トラッキング 0** | 外付けディスクを扱うことだけに集中。自動アップデートチェック以外の外部通信なし |
| **Developer ID + Apple 公証** | Gatekeeper を通過 — 「未確認の開発元」警告なしでそのまま開きます |
| **静かな自動アップデート** | 新しいバージョンが出るとメニューバーアイコンの横に小さな赤い点 + メニュー内項目で通知。モーダルは出ません。EdDSA + Apple Code Signing の二重検証後にインストール |

---

## ダウンロード

<div align="center">

### [最新リリースを入手 →](https://github.com/yooongZa/DiskOUT/releases/latest)

`DiskOUT-X.Y.Z.dmg` · 約 3MB · Apple Silicon 専用

</div>

### インストール (30 秒)

1. DMG をダブルクリック → **アプリケーション**フォルダにドラッグ
2. 初回起動時に macOS が一度確認 → **開く**をクリック
3. メニューバーに数字アイコンが表示 (外付けがなければ `0`)

### システム要件

- macOS 14 (Sonoma) 以降
- Apple Silicon (M1 / M2 / M3 / M4)

---

## 使い方

| 動作 | 方法 |
|---|---|
| 個別取り出し | メニューバーアイコン → ドライブ名クリック |
| 全て取り出し | メニュー「全て取り出し」または <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| 即座に全て取り出し | メニューバーアイコン**右クリック** |
| 取り出して スリープ | メニュー「取り出してスリープ」— すべて成功した場合のみスリープ開始 |
| マウントされていない外付けをマウント | メニュー下部セクションをクリックまたは <kbd>⌃</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| マウント + Finder で開く | マウントされていない外付けに <kbd>⌘</kbd>+クリック |
| 環境設定 | メニュー「設定…」または <kbd>⌘</kbd><kbd>,</kbd> |

### ログイン時自動起動

メニューの**「ログイン時に起動」**トグル → システムに自動登録。macOS が追加承認を求める場合、システム設定 → 一般 → ログイン項目で一度許可してください。

---

## FAQ

<details>
<summary><b>App Store に出ていない理由は?</b></summary>

mount / eject などのディスク操作は sandbox(サンドボックス) 環境で制約が多いです。安定性を十分に確保しにくいため、Developer ID 直接配布の路線を取りました。代わりに Apple 公証(notarization) を受けているため Gatekeeper は問題なく通過します。

</details>

<details>
<summary><b>安全ですか? データ損失の危険は?</b></summary>

手動取り出しは `diskutil eject` 標準パスを使います (Finder の「取り出し」と同じ)。自動(スリープ)取り出しは正常 unmount を先に試し、失敗した場合のみ force 段階に移行します。使用中のディスクは占有プロセスを診断して通知に表示します。

ただし、force 段階まで進んでも取り出せないディスクはそのままにして通知だけ出します — データ危険を冒してまで強制取り出しはしません。

</details>

<details>
<summary><b>無料ですか?</b></summary>

現在は無料ダウンロードです。今後のポリシー変更の可能性のためライセンスは「All rights reserved」としていますが、個人ユーザーが受け取って使う分には制限ありません。

</details>

<details>
<summary><b>GitHub アカウントなしでダウンロードできますか?</b></summary>

はい。`yooongZa/DiskOUT` は public リポジトリで、GitHub Releases の DMG も匿名でダウンロード可能です。GitHub への登録 / ログイン不要です。

</details>

<details>
<summary><b>Intel Mac でも動きますか?</b></summary>

現在のビルドは Apple Silicon 専用です。Intel ビルドの予定はありません。

</details>

<details>
<summary><b>「取り出し失敗」通知が出るのですが</b></summary>

DiskOUT の自動(スリープ)取り出しは正常 unmount 段階を先に試すため、通常は通知が出ません。それでも出るとしたら、通常以下のケースです。

- **使用中のアプリがあり正常 unmount 失敗 → force fallback に進行**: メニューの「force fallback」トグルが ON の時。
- **macOS が先に取り出しを始めたケース**: スリープ直前に他のシステムコンポーネントが先に試行。

解決: 外付けにアクセスしていたアプリを終了してからスリープ、または環境設定で force fallback を OFF。

</details>

---

## 既知の制限

- **クラムシェルモード (外部モニタ + 電源 + 蓋を閉じる)**: macOS が sleep(スリープ) 自体に入らない → 自動取り出しもトリガーされない。どのみちドック取り外しも起きないので安全。
- **使用中ドライブ**: 1 次正常取り出し失敗時に force unmount(強制マウント解除) を試みますが、占有アプリがある場合データ危険には依然注意が必要です。
- **ユーザーがスリープ中に外付けだけ抜いた場合**: アプリで扱える領域ではありません。スリープ中の安全取り出しが必要なら <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> 推奨 — wake(復帰) + 取り出しを一度に。
- **再マウントの信頼性**: 自動取り出しに成功したディスクだけ wake 後に再マウントします。物理的にすでに抜けたディスクはアプリで再マウントできません。

詳しい技術的制限は [CHANGELOG.md](CHANGELOG.md) を参照してください。

---

## 全機能

<details>
<summary>機能マトリクスを展開</summary>

| 機能 | 説明 |
|---|---|
| メニューバードロップダウン | 接続中の外付けドライブリスト。stale cache(古いキャッシュ) は即時表示し、background refresh(バックグラウンド更新) 完了後にメニューを再構築してウィンドウを開く遅延を減らす。更新失敗時は既存 cache を維持して失敗 row(行) を表示。**更新 source は DA event-driven インベントリが 1 番目** → SD カード挿入で `storagekitd` が詰まってもメニュー即座に正常 |
| **メニューバーアイコン = マウント数** | マウントされた外付け*デバイス*数を数字 (テキスト) で表示 — 0、1、2 … (上限なし)。マルチパーティション · RAID · APFS 合成ボリュームは 1 個に集計。`DAInventory` 変化にイベント基盤で自動更新 (ポーリングなし)。取り出し進行 / 結果表示中は臨時シンボル (↻ · ✓ · ✗) が優先 |
| **書き込み中ディスク表示** | 外付けに書き込み I/O が進行中なら、メニューバーの数字の横に小さな systemBlue `●` +「書き込み中 — 取り外さないでください」tooltip (アップデート通知の赤い `●` と色で区別)。メニューでは**書き込み中のそのディスク項目の横にだけ**青い `●` — どのディスクが busy か一目で識別。物理ディスクの I/O カウンタ (IORegistry) を 1.5s ポーリング、ボリューム→物理マッピングは parent-walk で RAID · APFS 合成 · 直結すべて処理。外付けがある時だけ稼働 (バッテリー) |
| **ディスク容量 / 使用率** | 各ディスクのメニュー項目の 2 行目に*空き / 全容量 (使用率 %)* を表示 — 例 `2.9 TB free of 7.3 TB (40% used)`。メニューを開く時に `URLResourceValues` で取得 (プロセス起動なし) |
| 個別取り出し | ドライブ名クリック |
| **書き込み中の取り出し確認** | 書き込み中のディスクを**手動**で取り出すと確認ダイアログ (force fallback がコピーを中断してファイル破損する事故を防止)。「取り出す」選択時のみ進行。sleep · 画面オフ · 自動経路は確認なしで従来の force 動作 |
| **占有アプリ終了して再試行** | 取り出し失敗時、ディスクを掴んでいる*終了可能な一般アプリ*があれば通知に「アプリを終了して再試行」ボタン。押すと graceful 終了 (`forceTerminate` は使わない) → 1 回再取り出し。Finder · システムデーモン · 自分自身は除外 |
| 全て取り出し | メニュー項目またはショートカット |
| **取り出してスリープ** | メニュー項目。sleep 系の volume-first force unmount(ボリューム優先強制マウント解除) パスで全て取り出し後、すべて成功した場合のみ `pmset sleepnow` でシステム sleep(スリープ) 開始。失敗があれば sleep 取消 + 通知 |
| グローバルホットキー (取り出し) | デフォルト <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> (日 / 英 IME 無関係、物理キーコード比較)。環境設定で E ベースの preset(プリセット) 変更可能 |
| グローバルホットキー (マウント) | デフォルト <kbd>⌃</kbd><kbd>⌘</kbd><kbd>E</kbd> — マウントされていない外付けを一括マウント。環境設定で変更可能 |
| 右クリック = 全て取り出し | メニューバーアイコン右クリックまたは ctrl+左クリック。環境設定 → Eject Behavior で OFF にすると右クリックがメニューを開く (誤取り出し防止 opt-out) |
| **マウントされていない外付けのマウント** | メニューに「マウントされていない外付け」セクション自動表示 (候補がある時のみ)。クリック = マウント、<kbd>⌘</kbd>+クリック = マウント + Finder で開く |
| **マウント / 未マウント状態の整合性** | `diskutil list -plist external` 1 つの snapshot(スナップショット) で mounted(マウント済み) / unmounted(マウントされていない) を一緒に計算し、実際にマウントがないのに mounted セクションに残る stale state(古い状態) を減らす |
| **ディスク種類アイコン** | `diskutil info -plist` の SD card 信号が確認されれば `sdcard` アイコン、その他外付けは `externaldrive` 系アイコンを使用 |
| **スリープ進入時**の自動取り出し | メニュートグル。IOKit power notification(電源通知) で sleep(スリープ) を少し遅らせ、各ディスクに対して正常 DA unmount(whole-disk 優先) → DA force unmount(whole-disk 優先) → `diskutil unmountDisk force` → `eject force` の順で試行。正常 unmount が通過すれば macOS の取り出し失敗通知が出ない |
| **画面が消える時も自動取り出し** (オプション) | メニュートグル、default OFF。`pmset sleep=0` (自動 sleep オフ) 環境のドック取り外し事故防止。sleep 系正常→force→`diskutil` 5 段階パス使用。頻繁な発動の懸念で明示的 opt-in |
| **wake / 画面オン時自動再マウント** | 自動取り出しに成功したディスクだけ再マウント。enumerate(列挙) されなければユーザーが分離したと見なして silent |
| **DMG / sparseimage 除外** | マウント済みイメージは `hdiutil info -plist` 1 秒 timeout + `diskutil info` fallback、unmounted 候補は `BusProtocol == "Disk Image"` で除外 |
| 取り出しパス | 手動取り出しは 1 次 `diskutil eject <volumePath>` → 失敗時 `diskutil unmount force <volumePath>` fallback。sleep / display sleep / 「取り出してスリープ」は **正常 DA unmount (whole disk 優先、2s)** → **DA force unmount (whole disk 優先、3s)** → `diskutil unmountDisk force` (6s) → `diskutil eject force` (5s) → `diskutil eject` (3s) の 5 段階。正常 unmount が通過すれば macOS の取り出し失敗通知が出ない。APFS multi-volume container も whole-disk option で一度に処理。最終失敗時、手動パスは `lsof` で占有 process / open file 診断を通知に追加 |
| 結果通知 | **無音** バナー + メニューバーアイコン ✓ / ⚠ / ✗。不在中発生または negative 結果 (失敗 · 再マウント失敗 · sleep 取り出し失敗) のみ**通知センターに保管**、本人 trigger + 成功はバナーのみ短時間表示 |
| 並列取り出し | `DispatchGroup` で N 個のドライブを同時取り出し |
| **ログイン時自動起動** | メニュートグル。`SMAppService.mainApp` 使用。`.requiresApproval` 状態もチェック表示 + 「ログイン項目の承認が必要」ラベルで表示 |
| **環境設定ウィンドウ** | <kbd>⌘</kbd><kbd>,</kbd> またはメニューの「設定…」で、ログイン起動、sleep / display sleep 取り出し、Music / Photos 終了、ショートカット (Eject all / Mount all / Eject and Sleep)、通知、force fallback、右クリック=全て取り出しトグル、About(バージョン / 著作権) を設定 |
| **ショートカット衝突自動修正** | 取り出し / マウント / 取り出してスリープのショートカットが同じ preset で保存されると衝突検出 + 別 preset に自動移動 + alert |
| **権限不足メニュー案内** | Accessibility(アクセシビリティ) / 通知権限が許可されていない状態だとメニュー上部に ⚠ 警告 row 表示。クリックでシステム設定の該当ページへ移動 |
| **通知の詳細制御** | 全体通知、成功通知、失敗通知をそれぞれトグル。デフォルトは全て ON |
| **多言語 (ko + en + ja + zh-Hans)** | `Localizable.xcstrings` 105 個のキー。初回起動でシステム言語を自動マッチング (対応外言語ユーザーは英語にフォールバック) + 環境設定 一般タブの Language ポップアップで強制選択可能 |
| **自動アップデート (Sparkle 2)** | 24 時間周期でバックグラウンドチェック。新バージョン発見時にダイアログを出さず**メニューバーアイコンに小さな systemRed `●` + メニュー内「🔴 新しいバージョン X.Y.Z 利用可能」項目**だけで表示 (gentle reminder)。ユーザーがクリックすると標準 Sparkle ダウンロード / インストールダイアログ → 自動再起動。EdDSA(Ed25519) + Apple Code Signing の二重検証。appcast ホスティングは GitHub Pages、DMG ホスティングは GitHub Releases — 無料運用 |
| **ディスク別自動取り出し除外** | ディスクメニュー項目 ▶ submenu の*「自動取り出しから除外」*トグル。Volume UUID 基準 (ケーブルスロットが変わっても維持)。自動 path だけ影響、明示的取り出しはそのまま。 |
| **Time Machine 自動保護** | TM バックアップディスクを自動識別 (`Backups.backupdb` / `.com.apple.timemachine.donotpresent` 検査) → 初回登場時に自動取り出しから除外 + 1 回通知。メニューに時計アイコン + *(Time Machine)* 表記 |
| **外付けライブラリアプリ処理** | メニュートグル (default OFF)。ON なら sleep 直前に Music / Photos 自動 quit (外付けライブラリ lock を解除して取り出し可能)、wake 後にバックグラウンドで自動 relaunch |

</details>

---

## 開発者向け

<details>
<summary>ビルド · インストール · 技術メモを展開</summary>

### 技術スタック

| 項目 | 値 |
|---|---|
| Bundle ID | `com.yongza.ejectdrives` |
| Hardened Runtime | YES |
| App Sandbox | **NO** (`ENABLE_APP_SANDBOX = NO`) |
| ビルドシステム | Xcodegen + xcodebuild |
| エントリポイント | `main.swift` (明示的 `NSApplication.shared.run()`) |
| ディスク操作 | 手動取り出しは `/usr/sbin/diskutil` を直接実行。sleep / display sleep / 「取り出してスリープ」は `Disk Arbitration API` の正常 unmount → force unmount → `diskutil` fallback の 5 段階パス |

### ファイル構成

```
diskOUT/
├── AppDelegate.swift            # メインロジック (diskutil 実行、メニューキャッシュ、sleep/wake 処理)
├── Localizable.xcstrings        # ko + en + ja + zh-Hans 翻訳 (Xcode String Catalog、105 キー)
├── main.swift                   # 明示的 entry point (NSApp.run)
├── Info.plist                   # bundle metadata (xcodegen 自動生成)
├── DiskOUT.entitlements         # 空の plist。project.yml の entitlements 明示でハマるのを防止
├── project.yml                  # xcodegen 設定 (sandbox OFF)
├── DiskOUT.xcodeproj/           # Xcode プロジェクト (xcodegen で再生成可能)
├── CHANGELOG.md
└── README.md
```

### ビルド

**一度だけ (プロジェクト生成)**

```bash
cd ~/Documents/diskOUT
xcodegen generate                  # project.yml → DiskOUT.xcodeproj
```

**毎ビルド**

```bash
cd ~/Documents/diskOUT
xcodebuild -project DiskOUT.xcodeproj -scheme DiskOUT -configuration Release \
  -derivedDataPath /tmp/DiskOUT-derived build
pkill -f DiskOUT
rm -rf ~/Applications/DiskOUT.app
cp -R /tmp/DiskOUT-derived/Build/Products/Release/DiskOUT.app ~/Applications/
open ~/Applications/DiskOUT.app
```

または Xcode を開いて `DiskOUT.xcodeproj` → <kbd>⌘</kbd><kbd>R</kbd>。

**安全インストール (ロールバック可能)**

新ビルドの検証が終わっていない時に推奨。既存の `.app` を先にバックアップしてから置換。

```bash
# 1. ビルド
cd ~/Documents/diskOUT
xcodebuild -project DiskOUT.xcodeproj -scheme DiskOUT -configuration Debug build

# 2. 終了 + バックアップ + 置換
pkill -f DiskOUT
mv ~/Applications/DiskOUT.app ~/Applications/DiskOUT.app.prev.bak
DERIVED=$(find ~/Library/Developer/Xcode/DerivedData -name "DiskOUT.app" -type d | head -1)
cp -R "$DERIVED" ~/Applications/DiskOUT.app
xattr -cr ~/Applications/DiskOUT.app   # provenance / quarantine 整理
open ~/Applications/DiskOUT.app

# 3. 検証
log show --predicate 'subsystem == "com.yongza.ejectdrives"' --info --last 1m

# 4a. 問題なければバックアップ除去
rm -rf ~/Applications/DiskOUT.app.prev.bak

# 4b. 問題があればロールバック
pkill -f DiskOUT
rm -rf ~/Applications/DiskOUT.app
mv ~/Applications/DiskOUT.app.prev.bak ~/Applications/DiskOUT.app
open ~/Applications/DiskOUT.app
```

### オプション変更箇所

大部分はメニューの**設定…**で直接変更。コード修正が必要な項目だけ:

| 変えること | 位置 |
|---|---|
| ショートカット preset 追加 | `AppDelegate.swift` の `SettingsHotkeyPreset` |
| 自動取り出しデフォルト値 | `SleepEject.enabled` の default 値 |
| 再マウント backoff 間隔 | `tryRemount(bsd:delays:operationID:)` 呼び出し時の `delays: [0, 1, 3, 7]` 修正 |
| メニューテキスト | `populateMenu(_:snapshot:isRefreshing:)` の文字列 |

キーコードは Carbon `Events.h` の `kVK_ANSI_*` 定数を参照。

### 診断メモ — `NSStatusBarWindow` height = 0

初期ビルド中、メニューバーに status item が表示されない問題発生。コードは 100% 正常動作 (NSLog 出力、statusItem / button / image すべて正常生成) なのにメニューバーには見えなかった。診断:

```
DIAG: NSApp.windows.count=1
DIAG window: class=NSStatusBarWindow frame=(0.0, 0.0, 32.0, 0.0) visible=true level=25
                                                            ^^^ height=0
```

`NSStatusBarWindow` は process 内には作られたが、`WindowServer` に登録されていないか、height=0 で閉じ込められていた。macOS 26 の新ポリシーまたは status item システムの微妙な変更と推定。

**回避コード** (`AppDelegate.swift` の `setupStatusItem`):

```swift
if let win = button.window {
    let thickness = NSStatusBar.system.thickness
    win.setFrame(NSRect(x: 0, y: 0, width: 32, height: thickness),
                 display: true, animate: false)
    win.orderFrontRegardless()
}
```

この 2 行が抜けるとメニューバーに表示されない。

### 診断メモ — 外付けドライブフィルタ

元のフィルタ:

```swift
guard !isInternal, isBrowsable, (isEjectable || isRemovable) else { continue }
```

macOS 26 では Thunderbolt 外付け SSD / 一部 USB が `isEjectable=false, isRemovable=false` で報告されるケース発見。修正:

```swift
guard !isInternal, isBrowsable, isLocal else { continue }
```

`isLocal` ガードでネットワークマウントだけ除外。外付けディスクはすべて通過。

### その他の細かい情報

- **ノッチモデル**: status items がメニューバー左側 (アプリメニューの隣) にも配置されることがある — 右側が満杯になるとノッチを越えて左側に登場。
- **`com.apple.provenance` xattr**: macOS の fileprovider サービス (iCloud Drive / OneDrive など) が `~/Documents/` 内のファイルに自動で付ける。codesign がこれを見ると「resource fork, Finder information, or similar detritus not allowed」でサイン拒否。`xattr -cr` で整理してもすぐ再付着。**ビルドは `/tmp/` など fileprovider 影響のない場所で行うのが安全。**
- **CGWindowList の限界**: `kCGWindowOwnerName == "DiskOUT"` 検索でウィンドウ 0 個でもメニューバーに表示されていることがある。`ControlCenter` が status item の view を自身のウィンドウ内に描画するケースがあり外部からは見えない。
- **`ProcessRunner` stdout/stderr drain**: `Process` の stdout / stderr を `readabilityHandler` で非同期 drain し、終了後に残った data も回収。`lsof` は 3 秒 timeout、`pmset sleepnow` は 5 秒 timeout。

</details>

---

<div align="center">

**DiskOUT** · © 2026 LIMOD · All rights reserved

[リリース](https://github.com/yooongZa/DiskOUT/releases) ·
[変更履歴](CHANGELOG.md) ·
[Issue](https://github.com/yooongZa/DiskOUT/issues)

</div>
