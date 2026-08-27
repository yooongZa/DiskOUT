<div align="center">

<img src="DiskOUT-eject-transparent.png" width="140" alt="DiskOUT">

# DiskOUT

[한국어](README.md) · [English](README.en.md) · [日本語](README.ja.md) · **简体中文**

## 别再看到“磁盘没有正常推出”。

<img src="DiskOUT-warning-en.png" width="620" alt="四条macOS磁盘没有正常推出警告叠放在一起的英文通知画面">

**DiskOUT 并不会隐藏系统通知。**

它会在合盖或已设置的空闲睡眠前尝试正常推出外置磁盘，从源头避免触发这条警告。

[![Download Latest](https://img.shields.io/github/v/release/yooongZa/DiskOUT?style=for-the-badge&label=Download&color=007AFF&logo=apple)](https://github.com/yooongZa/DiskOUT/releases/latest)

核心功能免费 · macOS 13+ · Apple Silicon · Apple 公证

[下载](https://github.com/yooongZa/DiskOUT/releases/latest) ·
[更新日志](https://github.com/yooongZa/DiskOUT/releases) ·
[反馈 / 问题](https://github.com/yooongZa/DiskOUT/issues) ·
[使用条款](TERMS.md) · [退款政策](REFUND_POLICY.md) · [隐私政策](PRIVACY.md)

</div>

---

## 不必每次都打开Finder

- 开启合盖自动推出后，关闭MacBook时会尝试正常推出目标磁盘。
- 也可以在已设置的空闲睡眠前自动推出。
- 通过睡眠自动推出且成功的磁盘会在Mac唤醒后重新挂载。
- 可通过菜单或快捷键执行单盘推出、全部推出和`推出并睡眠`。

> 请等到推出完成后再拔线。若在完成前或推出失败后断开，macOS仍可能显示警告。

## 正在写入的磁盘会单独处理

DiskOUT会先尝试正常卸载。手动推出和`推出并睡眠`在磁盘正在写入时会先征求确认；推出失败时，会显示原因和下一步操作。Time Machine磁盘和你排除的磁盘不会参与自动推出。

推出、挂载、睡眠自动化和数字菜单栏显示均免费。USD 4.99一次性Premium只是把数字换成菜单栏角色的可选功能。

---

## 下载

<div align="center">

### [获取最新版本 →](https://github.com/yooongZa/DiskOUT/releases/latest)

`DiskOUT-X.Y.Z.dmg` · 仅 Apple Silicon

</div>

### 安装 (30 秒)

1. 双击 DMG → 拖到**应用程序**文件夹
2. 首次启动时 macOS 会询问一次 → 点**打开**
3. 菜单栏出现数字图标 (没插外置则为 `0`)

### 系统要求

- macOS 13 (Ventura) 或更高
- Apple Silicon (M1 / M2 / M3 / M4)

---

## 使用方法

| 操作 | 方法 |
|---|---|
| 在“访达”中打开 / 推出单个 | 菜单栏图标 → 点击驱动器名称 / <kbd>⌘</kbd>+点击 |
| 全部推出 | 菜单"推出全部"或 <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| 立即全部推出 | 菜单栏图标**右键** |
| 推出并睡眠 | 菜单"推出并睡眠"— 全部成功才开始睡眠 |
| 挂载未挂载的外置 | 点击菜单底部区域或 <kbd>⌃</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| 挂载 + 在访达中打开 | <kbd>⌘</kbd>+点击未挂载的外置 |
| 设置 | 菜单"设置…"或 <kbd>⌘</kbd><kbd>,</kbd> |

### 登录时自动启动

请在“设置”→“通用”中启用**“登录时启动”**。如果 macOS 要求额外授权，请在系统设置 → 通用 → 登录项中允许一次。

---

## 常见问题

<details>
<summary><b>为什么不在 App Store?</b></summary>

mount / eject 等磁盘操作在 sandbox(沙盒) 环境中限制很多。难以充分保证稳定性,因此选择了 Developer ID 直接分发路线。代替方案是获得 Apple 公证(notarization),所以 Gatekeeper 仍然可以正常通过。

</details>

<details>
<summary><b>安全吗?有数据丢失风险吗?</b></summary>

手动推出使用标准的 `diskutil eject` 路径 (与访达的“推出”相同)。由DiskOUT管理的推出路径始终先尝试正常unmount。“推出并睡眠”和合盖仅在收到明确的busy响应且设置允许时尝试一次force；空闲/仅显示器睡眠不会force。判定为active/unknown的system sleep不会被DiskOUT干预。

但是,即使 force 阶段也无法推出的磁盘会保持原样并仅显示通知 — 不会冒数据风险强制推出。

</details>

<details>
<summary><b>免费吗?</b></summary>

是的。推出、挂载、睡眠自动化和现有数字显示将继续免费。可选的 Premium 菜单栏动画角色价格为 USD 4.99，一次购买永久使用；在 production 支付配置完成前，开发版本不会显示购买菜单。

</details>

<details>
<summary><b>可以将 Premium 转移到新 Mac 吗？</b></summary>

可以。购买后请在“设置”→“Premium”中选择“复制恢复代码…”，妥善保存 recovery code(恢复代码)，并在新 Mac 上使用它转移 Premium。转移后，旧 Mac 会在下次联网检查时失去权限。无法连接服务器时，最后一次验证的权限最多可继续使用 30 天。

</details>

<details>
<summary><b>没有 GitHub 账号也能下载吗?</b></summary>

可以。`yooongZa/DiskOUT` 是公开仓库,GitHub Releases 上的 DMG 也支持匿名下载。无需注册或登录 GitHub 即可下载。

</details>

<details>
<summary><b>Intel Mac 也能用吗?</b></summary>

当前版本仅支持 Apple Silicon。没有 Intel 版计划。

</details>

<details>
<summary><b>"未正确推出"警告仍然出现</b></summary>

DiskOUT 的自动 (睡眠) 推出会先尝试正常 unmount,通常不会触发通知。如果仍然出现,常见情况:

- **应用占用导致正常卸载失败**：仅当**允许强制卸载**已开启、回调明确报告磁盘忙，且操作来自手动推出、“推出并睡眠”或合盖时，才强制尝试一次。空闲/仅显示器睡眠不会强制卸载，也不会干预判定为active/unknown的system sleep。
- **macOS 先开始推出的情况**: 睡眠前另一个系统组件抢先尝试。

解决方法：先退出占用外置磁盘的应用再进入睡眠，或在设置中关闭**允许强制卸载**。

</details>

---

## 已知限制

- **合盖模式 (外接显示器 + 电源 + 合盖)**：即使macOS保持唤醒，raw lid-close信号仍会开始自动推出。如果要继续在合盖模式下工作，请关闭合盖自动推出。
- **睡眠来源判定**：macOS公开IOKit通知不会提供准确的请求来源。DiskOUT会放行没有紧邻idle信号或最近15秒合盖信号的active/unknown请求。与这些信号重叠的极少数直接请求可能会被归入idle/lid路径。
- **正在使用的驱动器**：“推出并睡眠”和合盖可在明确的busy响应后按设置尝试一次force unmount，因此正在进行的工作可能会中断。空闲/仅显示器睡眠不会force，也不会干预判定为active/unknown的system sleep。
- **安全推出完成前断开线缆**：在clean callback前或推出失败后拔线，仍可能触发macOS的未正确推出警告。请确认成功后再断开。
- **重新挂载的可靠性**: 只有自动推出成功的磁盘会在 wake 后重新挂载。已被物理移除的磁盘,应用无法重新挂载。

详细技术限制请参考 [发行说明](https://github.com/yooongZa/DiskOUT/releases)。

---

## 全部功能

<details>
<summary>展开功能矩阵</summary>

| 功能 | 说明 |
|---|---|
| 菜单栏下拉 | 列出已连接的外置驱动器。stale cache(陈旧缓存) 立即显示,然后在 background refresh(后台刷新) 完成后重新填充菜单,减少打开延迟。刷新失败时保留现有 cache 并显示失败 row(行)。**刷新 source 优先使用 DA 事件驱动的清单** → 即使 `storagekitd` 因插入 SD 卡而阻塞,菜单仍能立即正常响应 |
| **菜单栏图标 = ⏏ + 挂载数量** | 推出字形 (⏏) 与已挂载的外置*设备*数量并排显示 — 一眼即可识别是哪个应用的数字,等宽数字让数量变化时宽度不抖动。0 台时仅显示字形 (省略无信息的"0")。多分区 · RAID · APFS 合成卷算 1 个。基于 `DAInventory` 变化的事件驱动自动刷新 (无轮询)。推出进行 / 结果显示中使用临时符号 (↻ · ✓ · ✗) 优先,切换带 0.15s 淡入淡出 (尊重"减弱动态效果") |
| **读写活动提示** | 当外置磁盘有读取或写入 I/O 进行时,菜单栏数字旁出现小的 systemBlue `●` +「正在读取 / 写入 — 请勿断开」tooltip (与更新通知的红色 `●` 以颜色区分)。在菜单中,蓝色 `●` **仅出现在繁忙的那个磁盘项旁** — tooltip 区分读取 / 写入 / 两者。轮询物理磁盘 I/O 计数器 (IORegistry),间隔 1.5s;卷→物理映射通过 parent-walk 统一处理 RAID · APFS 合成 · 直连。读取采用更高阈值以避免后台索引的误报。推出后,确认最新挂载清单和物理映射后,会移除该磁盘的蓝点,并保留其他仍处于挂载状态的磁盘活动状态。仅在有外置磁盘时运行 (省电) |
| **磁盘容量 / 使用率** | 每个磁盘的菜单项第二行显示*可用容量 · 使用率* — 例如 `可用 2.9 TB · 已用 40%`。打开菜单时通过 `URLResourceValues` 读取 (无进程调用) |
| 在“访达”中打开 / 个别推出 | 点击驱动器名称 = 在“访达”中打开，<kbd>⌘</kbd>+点击 = 个别推出。列表下方无标题的磨砂提示框只显示 `打开驱动器文件夹（访达）` 和 `推出驱动器` 两行；开启“降低透明度”时改为不透明背景 |
| **写入中推出确认** | 手动推出正在写入的磁盘或选择 **“推出并睡眠”**时，会显示默认取消的警告。合盖处理可在 busy 响应后强制一次；空闲/仅显示器睡眠不会强制卸载 |
| **退出占用应用并重试** | 推出失败时,若有*可退出的常规应用*占用磁盘,通知提供「退出应用并重试」按钮。点击后优雅退出 (不用 `forceTerminate`) → 重试推出 1 次。排除 Finder · 系统守护进程 · 自身 |
| 全部推出 | 菜单项或快捷键 |
| **推出并睡眠** | 按物理磁盘并行执行整盘DA normal，仅在busy callback且**允许强制卸载**已开启时force一次。所有磁盘必须在10秒内clean成功才执行`pmset sleepnow`。失败、pending或`pmset`失败会取消睡眠；成功和延迟成功的磁盘保持已推出，等待用户明确重试 |
| 全局热键 (推出) | 默认 <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> (与 中/英 输入法无关,使用物理键码比较)。可在设置中修改 E 系列 preset(预设) |
| 全局热键 (挂载) | 默认 <kbd>⌃</kbd><kbd>⌘</kbd><kbd>E</kbd> — 批量挂载未挂载的外置。可在设置中修改 |
| 右键 = 全部推出 | 右键或 ctrl+左键点击菜单栏图标。在设置 → Eject Behavior 中关闭后,右键会打开菜单 (防止误推出 opt-out) |
| **挂载未挂载的外置** | 当有候选时菜单自动显示"未挂载的外置"区域。点击 = 挂载,<kbd>⌘</kbd>+点击 = 挂载 + 在访达中打开 |
| **挂载 / 未挂载状态一致性** | 通过 `diskutil list -plist external` 一个 snapshot(快照) 同时计算 mounted(已挂载) / unmounted(未挂载),减少实际未挂载但还残留在 mounted 区域的 stale state(陈旧状态) |
| **磁盘类型图标** | 通过 `diskutil info -plist` 确认 SD card 信号时使用 `sdcard` 图标,其他外置使用 `externaldrive` 系图标 |
| **空闲睡眠时**自动推出 | 在“设置”→“推出行为”中配置。仅macOS报告为idle sleep时才短暂延迟并执行整盘DA normal。DiskOUT判定为active/unknown的请求会立即交给系统处理 |
| **屏幕关闭时也自动推出** (可选) | 在“设置”→“推出行为”中配置，default OFF，适用于 `pmset sleep=0`。只做整盘 DA normal，成功的磁盘在屏幕唤醒后重新挂载 |
| **wake / 屏幕亮起时自动重新挂载** | 只有自动推出成功的磁盘会重新挂载。如果 enumerate(枚举) 不到,视为用户已分离,保持 silent |
| **DMG / sparseimage 排除** | 已挂载映像通过 `hdiutil info -plist` 1 秒 timeout + `diskutil info` fallback,未挂载候选通过 `BusProtocol == "Disk Image"` 排除 |
| 推出路径 | 手动推出使用`diskutil`和**允许强制卸载**设置。lid/idle/display sleep/“推出并睡眠”先做整盘DA normal；只有trigger与设置均允许且callback为busy时才force一次。timeout、物理断开或unknown error后不force |
| 结果通知 | **静音** banner + 菜单栏图标 ✓ / ! / ✗ (统一为 circle 系符号)。只有不在时发生或 negative 结果 (失败 · 重新挂载失败 · sleep 推出失败) 才**保留在通知中心**,本人 trigger + 成功仅短暂显示 banner |
| 并行推出 | 用 `DispatchGroup` 同时推出 N 个驱动器 |
| **登录时自动启动** | 在“设置”→“通用”中配置。使用 `SMAppService.mainApp`；`.requiresApproval` 以混合状态和“需要授权”标签显示，并引导至系统设置 |
| **设置窗口** | <kbd>⌘</kbd><kbd>,</kbd> 或菜单“设置…”。采用系统设置风格的**6 个工具栏面板** — 通用 (登录 · 语言 · 错误报告) / 推出行为 (sleep · display sleep · Music/Photos · 强制卸载 · 右键) / 通知 / 热键 / Premium (购买 · 恢复 · 状态) / About (版本 · 更新 · 链接)。窗口高度随面板自动调整，不直观的选项均带说明行 |
| **快捷键冲突自动修正** | 推出 / 挂载 / 推出并睡眠的快捷键保存为相同 preset 时检测冲突 + 自动移到其他 preset + alert |
| **权限缺失菜单提示** | Accessibility(辅助功能) / 通知权限处于未授权状态时,菜单顶部显示 ⚠ 警告 row。点击跳转到系统设置的相应页面 |
| **通知精细控制** | 可分别设置全部通知、成功通知和失败通知，默认全部开启。若 macOS 在“系统设置”中关闭了通知，应用会显示状态并可直接打开相应设置 |
| **多语言 (ko + en + ja + zh-Hans)** | `Localizable.xcstrings` 177 个 key。遍历完整的系统首选语言列表并选择第一个受支持语言，仅在全部不受支持时回退到英语。可在设置 → 通用 → Language 中选择跟随系统或明确指定语言 |
| **自动更新 (Sparkle 2)** | 24 小时周期后台检查。发现新版本时不弹出对话框,只在**菜单栏图标上显示小 systemRed `●` + 菜单内"更新到 X.Y.Z…"项 (带同色红点前缀)**(gentle reminder)。用户点击后,DiskOUT 会先关闭状态菜单并启动 Sparkle 检查,然后在检查中、更新提示以及无更新/错误模态窗口阶段,以有限次数重新请求前台显示。EdDSA(Ed25519) + Apple 代码签名双重验证。appcast 托管在 GitHub Pages,DMG 托管在 GitHub Releases — 免费运营 |
| **按盘自动推出排除** | 菜单底部*"自动推出排除的磁盘"* submenu 中按盘切换。基于 Volume UUID (即使线缆插槽改变也保持)。仅影响自动路径,显式推出不受影响。 |
| **Time Machine 自动保护** | 自动识别 TM 备份盘 (`Backups.backupdb` / `.com.apple.timemachine.donotpresent` 检查) → 首次出现时从自动推出中排除 + 1 次通知。菜单中显示时钟图标 + Time Machine 徽章 (macOS 14+,13 为括号标记) |
| **外置库应用处理** | 设置 → 推出行为开关 (default OFF)。开启后，会在自动 sleep/display sleep 推出或 **“推出并睡眠”**前正常退出 Music / Photos，以释放外置库 lock。仅在 wake 后于后台重新启动已接受退出的应用一次；重叠的 sleep 事件不会丢失重启记录 |

</details>

---

## 开发者说明

<details>
<summary>展开构建 · 安装 · 技术备注</summary>

### 技术栈

| 项目 | 值 |
|---|---|
| Bundle ID | `com.yongza.ejectdrives` |
| Hardened Runtime | YES |
| App Sandbox | **NO** (`ENABLE_APP_SANDBOX = NO`) |
| 构建系统 | Xcodegen + xcodebuild |
| 入口点 | `main.swift` (显式 `NSApplication.shared.run()`) |
| 磁盘操作 | 手动使用 `/usr/sbin/diskutil`。自动 sleep/display sleep/“推出并睡眠”使用整盘 Disk Arbitration normal，策略允许的 busy force 最多一次 |

### 文件结构

```
diskOUT/
├── AppDelegate.swift            # 主逻辑 (diskutil 执行、菜单缓存、sleep/wake 处理)
├── LanguageRuntime.swift        # 语言协商、存储值验证和安全重启策略
├── Localizable.xcstrings        # ko + en + ja + zh-Hans 翻译 (Xcode String Catalog,177 个 key)
├── main.swift                   # 显式 entry point (NSApp.run)
├── Info.plist                   # bundle metadata (xcodegen 自动生成)
├── DiskOUT.entitlements         # 空 plist。防止 project.yml 中 entitlements 明确指定的陷阱
├── project.yml                  # xcodegen 配置 (sandbox OFF)
├── DiskOUT.xcodeproj/           # Xcode 项目 (可通过 xcodegen 重新生成)
├── Tests/LanguageRuntimePolicyTests.swift # 语言回退、存储值和重启状态测试
├── CHANGELOG.md
└── README.md
```

### 构建

**一次性 (项目生成)**

```bash
cd ~/Documents/diskOUT
xcodegen generate                  # project.yml → DiskOUT.xcodeproj
```

**每次构建**

```bash
cd ~/Documents/diskOUT
BUILD_WORK_DIR="/private/tmp/diskout-build.$(uuidgen)"
xcodebuild -project DiskOUT.xcodeproj -scheme DiskOUT -configuration Release \
  -derivedDataPath "$BUILD_WORK_DIR/DerivedData" build
printf 'Built app: %s\n' "$BUILD_WORK_DIR/DerivedData/Build/Products/Release/DiskOUT.app"
```

安装请使用下方可回滚流程，或在 Xcode 中打开 `DiskOUT.xcodeproj` 后按 <kbd>⌘</kbd><kbd>R</kbd>。

**安全安装 (可回滚)**

新版本未完全验证时推荐。先备份现有 `.app` 再替换。

```bash
set -euo pipefail

# 1. 在明确的临时路径构建并验证 bundle ID
cd ~/Documents/diskOUT
INSTALL_WORK_DIR="/private/tmp/diskout-install.$(uuidgen)"
SOURCE_APP="$INSTALL_WORK_DIR/DerivedData/Build/Products/Release/DiskOUT.app"
TARGET_APP="$HOME/Applications/DiskOUT.app"
BACKUP_APP="$HOME/Applications/DiskOUT.app.backup.$(uuidgen)"
xcodebuild -project DiskOUT.xcodeproj -scheme DiskOUT -configuration Release \
  -derivedDataPath "$INSTALL_WORK_DIR/DerivedData" build
[ "$(plutil -extract CFBundleIdentifier raw -o - "$SOURCE_APP/Contents/Info.plist")" = \
  "com.yongza.ejectdrives" ]

# 2. 只结束准确的 process，并将旧应用保存到唯一目录
mkdir -p "$HOME/Applications"
pkill -x DiskOUT 2>/dev/null || true
if [ -e "$TARGET_APP" ]; then
  mv "$TARGET_APP" "$BACKUP_APP"
  printf 'Rollback backup: %s\n' "$BACKUP_APP"
else
  BACKUP_APP=""
  printf 'Rollback backup: none (没有旧安装)\n'
fi

# 3. 只安装已验证的 product 并启动
ditto "$SOURCE_APP" "$TARGET_APP"
xattr -cr "$TARGET_APP"
open "$TARGET_APP"

# 4. 验证
log show --predicate 'subsystem == "com.yongza.ejectdrives"' --info --last 1m
```

若有问题，请把上方输出的准确 backup 路径填入 `BACKUP_APP`。不要删除当前应用，先将它保存到唯一的 failed 路径，再恢复旧版本。

```bash
set -euo pipefail
TARGET_APP="$HOME/Applications/DiskOUT.app"
BACKUP_APP="<上方输出的 Rollback backup 绝对路径>"
FAILED_APP="$HOME/Applications/DiskOUT.app.failed.$(uuidgen)"
[ -d "$BACKUP_APP" ]
pkill -x DiskOUT 2>/dev/null || true
mv "$TARGET_APP" "$FAILED_APP"
mv "$BACKUP_APP" "$TARGET_APP"
open "$TARGET_APP"
printf 'Failed build preserved at: %s\n' "$FAILED_APP"
```

验证完成后，在 Finder 中把不再需要的 backup / failed 应用移到废纸篓。

### 选项修改位置

大部分在菜单的**设置…**中直接修改。只有需要改代码的项目:

| 修改对象 | 位置 |
|---|---|
| 添加快捷键 preset | `AppDelegate.swift` 中的 `SettingsHotkeyPreset` |
| 自动推出默认值 | `SleepEject.enabled` 的 default 值 |
| 重新挂载 backoff 间隔 | 调用 `tryRemount(bsd:delays:operationID:)` 时的 `delays: [0, 1, 3, 7]` |
| 菜单文本 | `populateMenu(_:snapshot:isRefreshing:)` 中的字符串 |

键码参考 Carbon `Events.h` 的 `kVK_ANSI_*` 常量。

### 诊断备注 — `NSStatusBarWindow` height = 0

早期版本中,菜单栏 status item 不显示的问题。代码 100% 正常运行 (NSLog 输出、statusItem / button / image 全部正常生成),但菜单栏中看不到。诊断:

```
DIAG: NSApp.windows.count=1
DIAG window: class=NSStatusBarWindow frame=(0.0, 0.0, 32.0, 0.0) visible=true level=25
                                                            ^^^ height=0
```

`NSStatusBarWindow` 在 process 中已创建,但没在 `WindowServer` 注册,或被困在 height=0。推测是 macOS 26 的新策略或 status item 系统的微妙变化。

**绕行代码** (`AppDelegate.swift` 的 `setupStatusItem`):

```swift
if let win = button.window {
    let thickness = NSStatusBar.system.thickness
    win.setFrame(NSRect(x: 0, y: 0, width: 32, height: thickness),
                 display: true, animate: false)
    win.orderFrontRegardless()
}
```

少了这两行菜单栏不显示。

### 诊断备注 — 外置驱动器过滤

原过滤器:

```swift
guard !isInternal, isBrowsable, (isEjectable || isRemovable) else { continue }
```

macOS 26 上发现 Thunderbolt 外置 SSD / 部分 USB 报告为 `isEjectable=false, isRemovable=false` 的情况。修改:

```swift
guard !isInternal, isBrowsable, isLocal else { continue }
```

`isLocal` 守卫仅排除网络挂载。所有外置磁盘都通过。

### 其他小细节

- **刘海机型**: status items 可能放在菜单栏左侧 (应用菜单旁) — 右侧装满时,会越过刘海到左侧出现。
- **`com.apple.provenance` xattr**: macOS 的 fileprovider 服务 (iCloud Drive / OneDrive 等) 会自动给 `~/Documents/` 中的文件加这个属性。codesign 见到这个会以 "resource fork, Finder information, or similar detritus not allowed" 拒签。`xattr -cr` 清理后仍会再附加。**为安全起见,在 `/tmp/` 等不受 fileprovider 影响的位置构建。**
- **CGWindowList 的限制**: `kCGWindowOwnerName == "DiskOUT"` 搜索可能返回 0 个窗口,但菜单栏图标实际显示着。`ControlCenter` 会把 status item 的 view 画在自己的窗口里,外部看不到。
- **`ProcessRunner` stdout/stderr drain**: 通过 `readabilityHandler` 异步 drain `Process` 的 stdout / stderr,结束后还会回收剩余 data。`lsof` 3 秒 timeout,`pmset sleepnow` 5 秒 timeout。

</details>

---

<div align="center">

**DiskOUT** · © 2026 LIMOD · 保留所有权利

[发布](https://github.com/yooongZa/DiskOUT/releases) ·
[更新日志](https://github.com/yooongZa/DiskOUT/releases) ·
[问题反馈](https://github.com/yooongZa/DiskOUT/issues) ·
[使用条款](TERMS.md) · [退款政策](REFUND_POLICY.md) · [隐私政策](PRIVACY.md)

</div>
