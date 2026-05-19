<div align="center">

<img src="DiskOUT-eject-transparent.png" width="180" alt="DiskOUT">

# DiskOUT

[한국어](README.md) · [English](README.en.md) · [日本語](README.ja.md) · **简体中文**

### Mac 必备的免费应用,DiskOUT 介绍。

**한국어 · English · 日本語 · 中文 (简体)** · 睡眠时自动推出 · Apple Silicon 原生

<br>

[![Download Latest](https://img.shields.io/github/v/release/yooongZa/DiskOUT?style=for-the-badge&label=Download&color=007AFF&logo=apple)](https://github.com/yooongZa/DiskOUT/releases/latest)

![macOS](https://img.shields.io/badge/macOS-14%2B-lightgrey?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-native-A855F7)
![Languages](https://img.shields.io/badge/i18n-4_languages-3B82F6)
![Developer ID](https://img.shields.io/badge/Developer_ID-signed-22C55E)
![Notarized](https://img.shields.io/badge/Apple-notarized-22C55E)

[下载](https://github.com/yooongZa/DiskOUT/releases/latest) ·
[更新日志](CHANGELOG.md) ·
[反馈 / 问题](https://github.com/yooongZa/DiskOUT/issues)

</div>

---

> Mac 是完美的 — 除了 *"未正确推出磁盘"* 通知。

## 什么都不用做,磁盘也能正确推出。完美。

现在合上 Mac,拔掉,装包,出门吧。

Apple 的 SSD 价格离谱,而且不能升级。只能靠外置硬盘撑着,但 *"Disk Not Ejected Properly"* 通知真烦人。装上 **DiskOUT**,你就不用再看到那种通知了。

---

## 怎么做到的?

### 1️⃣ 合上盖子的那一刻,所有外置都安全推出。

合 → 推出,开 → 挂载。
睡眠 → 推出,唤醒 → 挂载。

### 2️⃣ 10 个外置硬盘也一次性推出。

快捷键一次,菜单栏右键一次,全部推出。

### 3️⃣ 外置磁盘有几个,一眼看清。

菜单栏显示已连接磁盘的数量。

---

## 安心使用

|  |  |
|---|---|
| **Time Machine 自动保护** | TM 备份盘自动从自动弹出对象中排除 — 防止意外打断备份 |
| **忽略 DMG · 磁盘映像** | 已挂载的磁盘映像不会出现在菜单中,也不在自动弹出范围 |
| **不会出现"未正确推出"警告** | 睡眠时弹出会先尝试正常 unmount(卸载) — macOS 的 "improperly ejected" 通知不会触发 |
| **按盘选择性退出** | 可单独切换不想自动弹出的磁盘。基于 Volume UUID,即使换线缆或端口也保持设置 |
| **无广告 · 无追踪** | 只专注于外置磁盘。除自动更新检查外没有任何外部通信 |
| **Developer ID + Apple 公证** | 通过 Gatekeeper — 没有"未识别开发者"警告,直接打开 |
| **温和的自动更新** | 新版本到来时菜单栏图标旁出现一个小红点 + 菜单内显示对应项,不会弹出模态框。经过 EdDSA + Apple 代码签名双重验证后才安装 |

---

## 下载

<div align="center">

### [获取最新版本 →](https://github.com/yooongZa/DiskOUT/releases/latest)

`DiskOUT-X.Y.Z.dmg` · 约 3MB · 仅 Apple Silicon

</div>

### 安装 (30 秒)

1. 双击 DMG → 拖到**应用程序**文件夹
2. 首次启动时 macOS 会询问一次 → 点**打开**
3. 菜单栏出现数字图标 (没插外置则为 `0`)

### 系统要求

- macOS 14 (Sonoma) 或更高
- Apple Silicon (M1 / M2 / M3 / M4)

---

## 使用方法

| 操作 | 方法 |
|---|---|
| 弹出单个 | 菜单栏图标 → 点击驱动器名称 |
| 全部弹出 | 菜单"弹出全部"或 <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| 立即全部弹出 | 菜单栏图标**右键** |
| 弹出并睡眠 | 菜单"弹出并睡眠"— 全部成功才开始睡眠 |
| 挂载未挂载的外置 | 点击菜单底部区域或 <kbd>⌃</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| 挂载 + 在访达中打开 | <kbd>⌘</kbd>+点击未挂载的外置 |
| 设置 | 菜单"设置…"或 <kbd>⌘</kbd><kbd>,</kbd> |

### 登录时自动启动

切换菜单的**"登录时启动"** → 系统自动注册。如果 macOS 要求额外授权,在系统设置 → 通用 → 登录项中允许一次即可。

---

## 常见问题

<details>
<summary><b>为什么不在 App Store?</b></summary>

mount / eject 等磁盘操作在 sandbox(沙盒) 环境中限制很多。难以充分保证稳定性,因此选择了 Developer ID 直接分发路线。代替方案是获得 Apple 公证(notarization),所以 Gatekeeper 仍然可以正常通过。

</details>

<details>
<summary><b>安全吗?有数据丢失风险吗?</b></summary>

手动弹出使用标准的 `diskutil eject` 路径 (与访达的"推出"相同)。自动 (睡眠) 弹出会先尝试正常 unmount,只有失败时才进入 force 阶段。对于正在使用的磁盘,会通过 `lsof` 诊断占用进程并在通知中显示。

但是,即使 force 阶段也无法弹出的磁盘会保持原样并仅显示通知 — 不会冒数据风险强制弹出。

</details>

<details>
<summary><b>免费吗?</b></summary>

目前是免费下载。为以后政策变更的可能性留有余地,许可证设为 "All rights reserved",但个人用户下载使用没有限制。

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

DiskOUT 的自动 (睡眠) 弹出会先尝试正常 unmount,通常不会触发通知。如果仍然出现,常见情况:

- **有应用占用导致正常 unmount 失败 → 进入 force fallback**: 设置中"force fallback"开关为 ON 时。
- **macOS 先开始弹出的情况**: 睡眠前另一个系统组件抢先尝试。

解决方法: 退出占用外置的应用后再睡眠,或在设置中关闭 force fallback。

</details>

---

## 已知限制

- **合盖模式 (外接显示器 + 电源 + 合盖)**: macOS 本身不会进入 sleep → 自动弹出也不会触发。反正底座断开也不会发生,所以安全。
- **正在使用的驱动器**: 一次正常弹出失败时会尝试 force unmount(强制卸载),但如果占用应用仍在,仍需注意数据风险。
- **用户在睡眠中拔走外置的情况**: 应用无法处理的领域。如果需要睡眠中安全弹出,推荐 <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> — wake(唤醒) + 弹出一次完成。
- **重新挂载的可靠性**: 只有自动弹出成功的磁盘会在 wake 后重新挂载。已被物理移除的磁盘,应用无法重新挂载。

详细技术限制请参考 [CHANGELOG.md](CHANGELOG.md)。

---

## 全部功能

<details>
<summary>展开功能矩阵</summary>

| 功能 | 说明 |
|---|---|
| 菜单栏下拉 | 列出已连接的外置驱动器。stale cache(陈旧缓存) 立即显示,然后在 background refresh(后台刷新) 完成后重新填充菜单,减少打开延迟。刷新失败时保留现有 cache 并显示失败 row(行)。**刷新 source 优先使用 DA 事件驱动的清单** → 即使 `storagekitd` 因插入 SD 卡而阻塞,菜单仍能立即正常响应 |
| **菜单栏图标 = 挂载数量** | 已挂载的外置*设备*数量以数字 (文本) 显示 — 0、1、2 …(无上限)。多分区 · RAID · APFS 合成卷算 1 个。基于 `DAInventory` 变化的事件驱动自动刷新 (无轮询)。弹出进行 / 结果显示中使用临时符号 (↻ · ✓ · ✗) 优先 |
| 个别弹出 | 点击驱动器名称 |
| 全部弹出 | 菜单项或快捷键 |
| **弹出并睡眠** | 菜单项。使用 sleep 类型的 volume-first force unmount(卷优先强制卸载) 路径全部弹出后,只有全部成功才用 `pmset sleepnow` 启动系统 sleep(睡眠)。有失败则取消 sleep + 通知 |
| 全局热键 (弹出) | 默认 <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> (与 中/英 输入法无关,使用物理键码比较)。可在设置中修改 E 系列 preset(预设) |
| 全局热键 (挂载) | 默认 <kbd>⌃</kbd><kbd>⌘</kbd><kbd>E</kbd> — 批量挂载未挂载的外置。可在设置中修改 |
| 右键 = 全部弹出 | 右键或 ctrl+左键点击菜单栏图标。在设置 → Eject Behavior 中关闭后,右键会打开菜单 (防止误弹出 opt-out) |
| **挂载未挂载的外置** | 当有候选时菜单自动显示"未挂载的外置"区域。点击 = 挂载,<kbd>⌘</kbd>+点击 = 挂载 + 在访达中打开 |
| **挂载 / 未挂载状态一致性** | 通过 `diskutil list -plist external` 一个 snapshot(快照) 同时计算 mounted(已挂载) / unmounted(未挂载),减少实际未挂载但还残留在 mounted 区域的 stale state(陈旧状态) |
| **磁盘类型图标** | 通过 `diskutil info -plist` 确认 SD card 信号时使用 `sdcard` 图标,其他外置使用 `externaldrive` 系图标 |
| **进入睡眠时**自动弹出 | 菜单开关。通过 IOKit power notification(电源通知) 短暂延迟 sleep(睡眠),对每个磁盘按 正常 DA unmount(整盘优先) → DA force unmount(整盘优先) → `diskutil unmountDisk force` → `eject force` 的顺序尝试。正常 unmount 通过则不会触发 macOS 未正确推出通知 |
| **屏幕关闭时也自动弹出** (可选) | 菜单开关,default OFF。针对 `pmset sleep=0` (自动 sleep 关闭) 环境防止底座断开事故。使用 sleep 系正常→force→`diskutil` 5 阶段路径。因频繁触发顾虑而明确 opt-in |
| **wake / 屏幕亮起时自动重新挂载** | 只有自动弹出成功的磁盘会重新挂载。如果 enumerate(枚举) 不到,视为用户已分离,保持 silent |
| **DMG / sparseimage 排除** | 已挂载映像通过 `hdiutil info -plist` 1 秒 timeout + `diskutil info` fallback,未挂载候选通过 `BusProtocol == "Disk Image"` 排除 |
| 弹出路径 | 手动弹出 1 次 `diskutil eject <volumePath>` → 失败时 `diskutil unmount force <volumePath>` fallback。sleep / display sleep / "弹出并睡眠"使用 **正常 DA unmount (整盘优先,2s)** → **DA force unmount (整盘优先,3s)** → `diskutil unmountDisk force` (6s) → `diskutil eject force` (5s) → `diskutil eject` (3s) 5 阶段。正常 unmount 通过则不会触发 macOS 未正确推出通知。APFS multi-volume container 也通过 whole-disk option 一次处理。最终失败时,手动路径还会向通知添加 `lsof` 的占用 process / open file 诊断 |
| 结果通知 | **静音** banner + 菜单栏图标 ✓ / ⚠ / ✗。只有不在时发生或 negative 结果 (失败 · 重新挂载失败 · sleep 弹出失败) 才**保留在通知中心**,本人 trigger + 成功仅短暂显示 banner |
| 并行弹出 | 用 `DispatchGroup` 同时弹出 N 个驱动器 |
| **登录时自动启动** | 菜单开关。使用 `SMAppService.mainApp`。`.requiresApproval` 状态也会以勾选 + "登录项需要授权"标签显示 |
| **设置窗口** | <kbd>⌘</kbd><kbd>,</kbd> 或菜单"设置…"。可设置登录时启动、sleep / display sleep 弹出、Music / Photos 退出、快捷键 (Eject all / Mount all / Eject and Sleep)、通知、force fallback、右键=全部弹出开关、About(版本 / 版权) |
| **快捷键冲突自动修正** | 弹出 / 挂载 / 弹出并睡眠的快捷键保存为相同 preset 时检测冲突 + 自动移到其他 preset + alert |
| **权限缺失菜单提示** | Accessibility(辅助功能) / 通知权限处于未授权状态时,菜单顶部显示 ⚠ 警告 row。点击跳转到系统设置的相应页面 |
| **通知精细控制** | 全部通知、成功通知、失败通知可分别切换。默认全部 ON |
| **多语言 (ko + en + ja + zh-Hans)** | `Localizable.xcstrings` 105 个 key。首次启动按系统语言自动匹配 (不支持的语言用户回退到英语) + 设置 通用标签的 Language 弹出菜单中可强制选择 |
| **自动更新 (Sparkle 2)** | 24 小时周期后台检查。发现新版本时不弹出对话框,只在**菜单栏图标上显示小 systemRed `●` + 菜单内"🔴 新版本 X.Y.Z 已可用"项**(gentle reminder)。用户点击后才出现标准 Sparkle 下载 / 安装对话框 → 自动重启。EdDSA(Ed25519) + Apple 代码签名双重验证。appcast 托管在 GitHub Pages,DMG 托管在 GitHub Releases — 免费运营 |
| **按盘自动弹出排除** | 磁盘菜单项 ▶ submenu 的*"从自动弹出中排除"*开关。基于 Volume UUID (即使线缆插槽改变也保持)。仅影响自动路径,显式弹出不受影响。 |
| **Time Machine 自动保护** | 自动识别 TM 备份盘 (`Backups.backupdb` / `.com.apple.timemachine.donotpresent` 检查) → 首次出现时从自动弹出中排除 + 1 次通知。菜单中显示时钟图标 + *(Time Machine)* 标记 |
| **外置库应用处理** | 菜单开关 (default OFF)。ON 时 sleep 前自动 quit Music / Photos (释放外置库 lock 以便弹出),wake 后在后台自动 relaunch |

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
| 磁盘操作 | 手动弹出直接执行 `/usr/sbin/diskutil`。sleep / display sleep / "弹出并睡眠"使用 `Disk Arbitration API` 的正常 unmount → force unmount → `diskutil` fallback 5 阶段路径 |

### 文件结构

```
diskOUT/
├── AppDelegate.swift            # 主逻辑 (diskutil 执行、菜单缓存、sleep/wake 处理)
├── Localizable.xcstrings        # ko + en + ja + zh-Hans 翻译 (Xcode String Catalog,105 个 key)
├── main.swift                   # 显式 entry point (NSApp.run)
├── Info.plist                   # bundle metadata (xcodegen 自动生成)
├── DiskOUT.entitlements         # 空 plist。防止 project.yml 中 entitlements 明确指定的陷阱
├── project.yml                  # xcodegen 配置 (sandbox OFF)
├── DiskOUT.xcodeproj/           # Xcode 项目 (可通过 xcodegen 重新生成)
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
xcodebuild -project DiskOUT.xcodeproj -scheme DiskOUT -configuration Release \
  -derivedDataPath /tmp/DiskOUT-derived build
pkill -f DiskOUT
rm -rf ~/Applications/DiskOUT.app
cp -R /tmp/DiskOUT-derived/Build/Products/Release/DiskOUT.app ~/Applications/
open ~/Applications/DiskOUT.app
```

或在 Xcode 中打开 `DiskOUT.xcodeproj` → <kbd>⌘</kbd><kbd>R</kbd>。

**安全安装 (可回滚)**

新版本未完全验证时推荐。先备份现有 `.app` 再替换。

```bash
# 1. 构建
cd ~/Documents/diskOUT
xcodebuild -project DiskOUT.xcodeproj -scheme DiskOUT -configuration Debug build

# 2. 结束 + 备份 + 替换
pkill -f DiskOUT
mv ~/Applications/DiskOUT.app ~/Applications/DiskOUT.app.prev.bak
DERIVED=$(find ~/Library/Developer/Xcode/DerivedData -name "DiskOUT.app" -type d | head -1)
cp -R "$DERIVED" ~/Applications/DiskOUT.app
xattr -cr ~/Applications/DiskOUT.app   # 清理 provenance / quarantine
open ~/Applications/DiskOUT.app

# 3. 验证
log show --predicate 'subsystem == "com.yongza.ejectdrives"' --info --last 1m

# 4a. 没问题就删除备份
rm -rf ~/Applications/DiskOUT.app.prev.bak

# 4b. 有问题就回滚
pkill -f DiskOUT
rm -rf ~/Applications/DiskOUT.app
mv ~/Applications/DiskOUT.app.prev.bak ~/Applications/DiskOUT.app
open ~/Applications/DiskOUT.app
```

### 选项修改位置

大部分在菜单的**设置…**中直接修改。只有需要改代码的项目:

| 修改对象 | 位置 |
|---|---|
| 添加快捷键 preset | `AppDelegate.swift` 中的 `SettingsHotkeyPreset` |
| 自动弹出默认值 | `SleepEject.enabled` 的 default 值 |
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
[更新日志](CHANGELOG.md) ·
[问题反馈](https://github.com/yooongZa/DiskOUT/issues)

</div>
