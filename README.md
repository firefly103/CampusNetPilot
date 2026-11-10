# 校园网助手（CampusNetPilot）

macOS 14+ 菜单栏小工具：**合盖静默 → 开盖判断当前 Wi-Fi → 必要时扫描一次并切到宿舍网络 → 只在校园网下按需认证**。
面向 MacBook Air M3，Swift + SwiftUI（必要时 AppKit），Wi-Fi 走 CoreWLAN，凭据放 Keychain，构建用 Swift Package Manager + 脚本 + GitHub Actions。

---

## 1. 它做什么、不做什么

**做：**

- 合盖／系统睡眠时暂停一切网络活动（扫描、切换、联网检测、认证），取消定时器与进行中的请求，丢弃旧结果。
- 开盖后按当前 SSID 分四种情况处理：白名单静默 / 校园网（先找宿舍网络，再按需认证）/ 未连接（扫一次）/ 其他网络静默。
- 只在"明确配置为校园网"的 SSID 上提交认证；每次提交前重新确认 SSID。
- 校园网在线时不重复登录；掉线后按需重新认证，失败走上限退避，密码错误则停止自动重试。
- 可选定时扫描（默认关闭），仅在开盖 + 校园网时运行，切走后立即停止。
- 状态、日志、配置检查全部在菜单栏面板与设置页里，日常零弹窗。

**不做：**

- 不改动系统 Wi-Fi/蓝牙开关，不改电源设置，不阻止睡眠，不主动唤醒。
- 不改路由 / DNS / 代理 / 网络服务顺序 / 其他网络的"自动加入"。
- 不按信号强度选网（宿舍网络是固定优先级）。
- 不硬编码 `en0`，不调用 `airport` 私有命令，不通过关闭再打开 Wi-Fi 来切换。
- 不"保活"：掉线恢复只表示"检测到问题并按需重新认证"，不保证不断线。
- 不通过持续定位获取坐标（只读 Wi-Fi 名称）。

---

## 2. 状态机一览

| 状态 | 触发条件 | 行为 |
|---|---|---|
| 合盖／睡眠暂停 | 物理合盖、系统睡眠（含盖子仍合上的后台维护唤醒） | 取消所有定时器与请求，丢弃旧结果，不写高频日志；熄屏/锁屏**不**进入此状态 |
| 白名单静默 | 连上白名单 SSID（宿舍 Wi-Fi、热点…） | 不扫描、不探测、不认证；即使暂时没网也不切走 |
| 其他网络静默 | 连上既非校园也非白名单的 SSID | 保持静默，不主动切走 |
| 正在切换 | 一次有界扫描命中宿舍优先网络 | 尝试关联；成功→白名单静默；失败→重读实际连接后回到校园网处理 |
| 校园网在线 | 校园 SSID + 联网检测通过 | 不重复登录，按 `connectivityInterval` 复查 |
| 正在认证 | 校园 SSID + 检测未通过 / 门户拦截 | 提交 SRun 或 ePortal；失败退避 10/30/120/300/600 秒 |
| 未连接 | 无 SSID | 扫一次找宿舍网络；找不到则等系统自动连接（最多 2 次复查） |
| 权限或配置问题 | SSID 不可读 / 接口不可用 / 缺账号密码 / 密码错误 | 停止自动操作，菜单栏与设置页给出可诊断说明 |

关键不变量：**每轮任务都绑定 `epoch`（网络状态版本）**。合盖、暂停、切网、配置变更都会让 `epoch+1`
并取消当前请求，因此"合盖前的扫描结果"永远无法在合盖后触发切换或认证。

---

## 3. 参考项目核实结论

2026-11-10 通过 GitHub API 核实（仓库元数据、目录树、关键源码）：

| 项目 | 语言 / 许可证 | 结论 |
|---|---|---|
| `ATMLuck/AutoSZUWeb` | C++17 / MIT | **主参考**。SRun 流程（`ac_id` → `get_challenge` → XXTEA + 定制 Base64 `info` → SHA1 `chksum` → `srun_portal`）、ePortal 流程、成功判定、失败分类、按天日志、自启动思路均可用；窗口/Windows/Linux 实现未采用。其 `src/srun.cpp` 关闭了 TLS 校验，本项目**保留**系统默认校验证书与主机名。 |
| `coderask/auto-wifi` | Swift / 无 LICENSE 文件 | 仅参考 CoreWLAN 扫描/关联与"不要反复切换"的设计；**未复制代码**。 |
| `metacometdave/SleepWatch` | Python / MIT | 仅参考睡眠/唤醒事件处理；其"合盖关 Wi-Fi/蓝牙"的行为**未采用**。 |
| `Johnny-Kao/Wi-Fi-Auto-Switching-Tool` | Python / 无 LICENSE 文件 | 仅参考"已知网络 → 扫描 → 切换"的流程；**未复制代码**，且不使用其信号强度策略。 |

详细归属与差异见 `THIRD_PARTY_NOTICES.md`。

**API 适用性核对（Apple 官方文档）：**

- `CWWiFiClient` / `CWInterface.ssid()` / `bssid()` / `scanForNetworks(withSSID:)` / `associate(to:password:)` 均为 CoreWLAN 公开 API，仍然可用；未使用任何 `airport` 命令行。
- 菜单栏：`MenuBarExtra`（macOS 13+）+ `Window` 场景；`LSUIElement=true` 隐藏 Dock 图标。
- 登录项：`SMAppService.mainApp`（macOS 13+），不再手写 LaunchAgent。
- 电源事件：`NSWorkspace.willSleep/didWake/screensDidSleep/screensDidWake`；盖子状态读 `IOPMrootDomain` 的 `AppleClamshellState`（IORegistry 属性，只读出 Bool）。
- 网络变化：`CWEventDelegate`（SSID/BSSID/链路/电源）+ `NWPathMonitor` 作为兜底，二者都带 1.5 秒防抖。

---

## 4. 目录结构

```
Package.swift                 # SPM：CampusNetCore（可测）+ CampusNetPilot（macOS 菜单栏 App）
Sources/CampusNetCore/        # 平台无关：配置、状态机、SRun/ePortal、探测、日志
  Config.swift  ConfigStore.swift  Crypto.swift  Auth.swift  Probe.swift
  Interfaces.swift  Status.swift  Engine.swift
Sources/CampusNetPilot/       # macOS 专属：SwiftUI + CoreWLAN + IOKit + Security
  CampusNetPilotApp.swift  AppModel.swift  MenuBarPanel.swift  SettingsView.swift
  WiFiService.swift  KeychainStore.swift  LaunchAtLogin.swift
Tests/CampusNetCoreTests/     # 59 个用例（Linux/macOS 都能跑）
Packaging/Info.plist          # .app 的 Info.plist 模板（含权限说明、LSUIElement）
Scripts/check-toolchain.sh    # 只依赖 CLT 的环境自检
Scripts/build-app.sh          # 构建 → 组装 .app → ad-hoc 签名 → 校验 → zip
.github/workflows/build.yml   # macOS runner：测试 + arm64 .app + artifact
examples/config.example.json  # 不含秘密的配置示例
tools/srun_reference.py       # SRun 算法 Python 参考 + 已知答案生成器
docs/TEST_REPORT.md           # 已执行的测试与覆盖矩阵
```

---

## 5. 拿到可运行的 .app

### 5.1 GitHub Actions（推荐，MacBook 不需要装 Xcode）

1. 把仓库推到 GitHub（默认分支 `main`）。
2. 打开 **Actions → build → Run workflow**（`workflow_dispatch` 已开启；push / PR 也会自动跑）。
3. 跑完后在本次 run 的 **Artifacts** 里下载 **`CampusNetPilot-macos-arm64`**。
4. 解压得到 `CampusNetPilot.app`，拖进 `/Applications`。
5. artifact 里同时有 `*.sha256`，可用 `shasum -a 256 -c CampusNetPilot-*.zip.sha256` 校验。产物保留 **3 天**（`retention-days: 3`），使用 GitHub 标准 `macos-15` runner，不使用付费大型 runner。

工作流做的事：`swift test`（核心逻辑）→ `Scripts/build-app.sh`（release 构建、组装 .app、ad-hoc 签名、
`codesign --verify`、`lipo -info` 断言 arm64、`plutil -lint`）→ 上传 zip。

### 5.2 本机构建（只需要 Command Line Tools）

```bash
xcode-select --install            # 已装可跳过
git clone <this repo> && cd CampusNetPilot
./Scripts/check-toolchain.sh      # 缺 swift / SDK / codesign 等会明确报错并退出
./Scripts/build-app.sh            # 产物：dist/CampusNetPilot.app 与 dist/CampusNetPilot-<ver>-arm64.zip
```

可选参数：`VERSION=1.2.0 BUILD_NUMBER=42 ./Scripts/build-app.sh`、`./Scripts/build-app.sh --no-zip`。

> 本机构建需要 macOS + macOS 14+ SDK。Windows 上只能跑核心逻辑测试（见第 10 节），
> 不能把 Windows 上的编译通过当成 macOS 构建通过。

### 5.3 首次启动（未公证）

产物是 **ad-hoc 签名**（`codesign --sign -`）：不是 Developer ID 签名，也没有经过 Apple 公证。
所以第一次打开会被 Gatekeeper 拦：

- 方式 A：在 Finder 里 **右键 → 打开 → 打开**。
- 方式 B：`xattr -d com.apple.quarantine /Applications/CampusNetPilot.app`（只移除本应用的隔离标记）。

**不需要**关闭"系统完整性保护"或全局降低安全设置。

ad-hoc 签名的现实影响（不是 bug）：

- 重新构建后签名指纹变化，**定位授权与钥匙串访问可能被系统重新询问**；
- 每次重新打包都建议观察一次权限状态（设置页 → 关于 / 菜单栏状态）。

---

## 6. 权限

| 权限 | 什么时候需要 | 不给会怎样 |
|---|---|---|
| 定位服务（Location Services） | 读取 SSID/BSSID、扫描网络。macOS 把 Wi-Fi 名称视为可推断位置的信息 | 读不到 SSID → 状态显示"权限或配置问题"，**不认证、不切换**，面板里有跳转按钮 |
| 钥匙串（Keychain） | 保存校园密码、可选的宿舍 Wi-Fi 密码 | 密码读不到 → 显示"配置缺失"，不会提交认证 |
| 登录项（SMAppService） | 你打开"登录后自启动" | 注册失败会在设置页显示具体原因 |

Info.plist 已包含 `NSLocationUsageDescription` 与 `NSLocationWhenInUseUsageDescription`。
本应用**从不**请求定位更新、不读取坐标、不写位置文件——只用 CoreWLAN 读网络名。

---

## 7. 配置

- 配置文件：`~/Library/Application Support/CampusNetPilot/config.json`（不含密码，权限 `0600`）。
- 密码：钥匙串 service `com.example.CampusNetPilot`，账号 `campus.password` 与 `wifi.password.<SSID>`。
- 所有编辑都在设置页完成（**密码只通过安全输入框写入钥匙串**），改完点"保存配置"。

字段（示例见 `examples/config.example.json`）：

| 字段 | 说明 |
|---|---|
| `campusSSIDs` | 校园 Wi-Fi SSID 列表，精确匹配（支持中文、空格、特殊字符） |
| `whitelistSSIDs` | 静默白名单；宿舍优先网络会被自动并入 |
| `dormNetworks` | 宿舍优先网络，**数组顺序即优先级**；可选 `bssid` 限定单个 AP；`requiresPassword` 决定是否读取钥匙串口令 |
| `campusUsername` / `campusAuthMode` | 认证账号 / `srun`、`eportal`、`disabled` |
| `srunBaseURL` / `eportalLoginURL` | SRun 根地址；ePortal 登录地址（可留空） |
| `srunXXTEAVariant` | `reference`（默认，与参考实现一致）或 `standard`（官方 XXTEA 宏） |
| `connectivityInterval` | 校园网在线检测间隔，默认 30 秒，钳制 15–3600 |
| `scheduledScanEnabled` / `scheduledScanInterval` | 定时扫描开关（默认关）/ 间隔（默认 180 秒，钳制 60–3600） |
| `probeURLs` | 联网检测端点（多个，全部失败才判离线） |
| `launchAtLogin` | 登录后自启动 |

首次启动时**没有任何预置 SSID**：状态会显示"未配置"，不会对未知网络认证。

---

## 8. 行为细节

### 合盖 / 睡眠

- 物理合盖：`IOPMrootDomain.AppleClamshellState` 变 true → 暂停。检测方式：睡眠/唤醒/屏幕事件即时触发，外加一段**低频 IORegistry 读取**兜底——盖子打开时 10 秒一次（尽快发现合盖），合上后退到 30 秒一次（只需要发现"重新开盖"），全程不涉及网络、不写日志。
- 每 10/30 秒那次读取只读一个 Bool，不会扫描、不会探测、不会认证；合盖后所有定时器与请求由状态机 `cancelAll` 清空。
- 动作前复检：状态机在**每次扫描、切换、探测、认证之前**都会再问一次盖子状态，已合上则立即暂停并放弃该动作。这把"合盖但系统没睡"（外接显示器）的暴露窗口从"最多一个轮询周期"压到"一次本地读 IORegistry 的耗时"。
- **这仍然不是零窗口**，如实说明边界：复检通过后到请求真正发出之间仍可能合盖；已发出的 HTTP 请求会被 `Task.cancel()` 取消，但服务端可能已经处理完；`scanForNetworks` / `associate(to:)` 是 CoreWLAN 同步 API，**不可中断**，只能丢弃其结果（`epoch` 校验）。因此本应用保证的是"**发现即停、结果作废**"，不是"原子性取消"。
- 系统睡眠：`NSWorkspace.willSleepNotification` → 暂停并关闭日志文件句柄。
- 唤醒：判断依据是**物理盖子 + 系统睡眠状态**，不看屏幕是否点亮：
  - 盖子合上（后台维护唤醒）→ 保持暂停，不扫描、不认证；
  - 盖子打开 → 恢复并重新判断，即使屏幕还没亮。
- **熄屏、锁屏不影响监控**：盖子打开时状态机继续按间隔做校园网检测；屏幕事件只顺带刷新一次盖子状态，不产生暂停/恢复事件。

### 开盖

1. 等接口稳定（一次有界扫描，最多 3 次尝试、间隔 2.5 秒，绝不变成持续扫描）。
2. 已连白名单 / 其他网络 → 什么都不做。
3. 已连校园网 → 扫一次找宿舍优先网络（按配置顺序，不看信号强度）：
   - 找到 → 切换；成功后进入静默（停止扫描与认证）；
   - 没找到 → 保留校园连接，检测联网，需要则认证；
   - 切换失败 → 重读实际连接；仍是校园网才走认证流程，并在 90 秒内不再尝试切换。
4. 未连接 → 扫一次；找不到则等系统自动连接（最多 2 次、间隔 8 秒复查），连上后按实际 SSID 处理。

### 开盖期间

- 判断依据是**连接指纹**而非单一 SSID：`SSID + 接口名 + IPv4 + 连接状态 + BSSID`。
  - 断开/重连（连接状态翻转）、换 SSID、换接口、换 IP → 视为真实变化：`epoch+1`、取消在途请求、重新评估；
  - 同 SSID 仅 BSSID 变化（AP 漫游）或纯重复通知 → 只刷新定时器，不取消进行中的扫描/认证、不重扫、不重认证。
- 因此"同 SSID 但重新拿了地址/换了接口"不会被误当作重复通知放过。
- 只有"开盖 / 开盖状态下启动 / 手动判断"会触发宿舍网络扫描，普通网络变化不会。
- 手动选的其他网络不会被立刻切走。

### 认证与退避

- 在线不登录；离线才认证；提交前再读一次 SSID。
- 失败退避：10 / 30 / 120 / 300 / 600 秒（封顶）。
- 明确"密码错误"→ 置为阻断状态，停止自动重试；手动"重新判断"、网络变化或改配置后才会再试。

### 定时扫描（可选）

默认关闭。开启后仅在 **开盖 + 校园网** 时按间隔扫描；切换成功、合盖、睡眠、Wi-Fi 关闭、离开校园网、
关闭开关都会立即取消定时器（测试里有断言，不留残余 timer）。连续失败按 2×/4×/8× 退避，且有 90 秒切换冷却。

---

## 9. 日志、自启动、退出与卸载

- 日志：内存最近 400 条（面板 25 条 / 设置页全部）+ `~/Library/Application Support/CampusNetPilot/logs/app-YYYY-MM-DD.log`。
- 脱敏：日志写入前会把 `password=`、`token=`、`chksum=` 等参数值替换为 `***`；不记录完整请求 URL。
- 自启动：设置页开关 → `SMAppService`；状态文字会显示"未启用 / 已启用 / 需要在登录项中允许 / 系统未找到应用"。
- 退出：菜单栏面板"退出"，或 `⌘Q`。
- 卸载：
  1. 退出应用，删除 `/Applications/CampusNetPilot.app`；
  2. 删除 `~/Library/Application Support/CampusNetPilot`（配置与日志）；
  3. 打开"钥匙串访问"删除 `com.example.CampusNetPilot` 条目（密码）；
  4. 系统设置 → 通用 → 登录项 里移除残留；
  5. 系统设置 → 隐私与安全性 → 定位服务 里移除条目。

---

## 10. 测试

- 核心逻辑 68 个用例，**已在本次交付中实际执行并通过**（Swift 6.0.3，Linux，WSL2）：

  ```
  swift test
  Test Suite 'All tests' passed — 68 tests, 0 failures
  ```

  详细清单、与需求第九节 14 条验收项的对应关系、以及"为什么这些还不能算真机验证"见
  [`docs/TEST_REPORT.md`](docs/TEST_REPORT.md)。
- macOS 上的编译与打包由 `.github/workflows/build.yml` 完成；工作流会重新跑一遍 `swift test`
  （在 macOS SDK 下同时编译 UI 目标），再构建 `.app` 并断言 arm64。
- 测试技巧：
  - Wi-Fi / 探测 / 认证 / 定时器全部走协议注入，状态机不依赖任何系统框架；
  - "合盖时仍在进行的扫描"用 `Gate`（continuation）卡住，合盖后再放行，验证结果被丢弃；
  - SRun 载荷用 `tools/srun_reference.py` 生成已知答案，Swift 端逐字节比对。

---

## 11. 待真机验证清单（请按顺序做一遍）

1. `./Scripts/check-toolchain.sh` 通过；`dist/CampusNetPilot.app` 能启动，菜单栏出现图标、Dock 无图标。
2. 首次读 SSID 时系统弹出定位权限；允许后状态能显示当前 SSID；拒绝后状态显示"权限或配置问题"且不发任何认证请求。
3. 配置校园 SSID + 账号 + 密码（钥匙串），开盖连校园网：日志出现"扫描 → 未发现宿舍网络 → 提交认证 → 成功"。
4. 在教室合盖 1 分钟再开盖：合盖期间日志无新增扫描/认证；开盖后最多一次扫描。
5. 回宿舍开盖（仍连校园网、宿舍 Wi-Fi 可见）：切到宿舍 Wi-Fi 后进入"白名单静默"，且**没有**联网探测与认证。
6. 宿舍 Wi-Fi 关闭再开盖：只扫一次，认证一次，不出现连续跳网。
7. 外接显示器合盖不睡：状态应在 10 秒内变为"合盖暂停"；同时观察日志，合盖瞬间前后不应出现新的扫描/认证（说明前置盖子检查生效）。
8. 熄屏/锁屏但开盖：状态不应显示"合盖"。
9. 开启"定时扫描"（180 秒）连校园网：每 180 秒一次扫描；切到宿舍 Wi-Fi 后定时器停止（日志不再出现定时扫描）。
10. 校园网认证掉线（或手动注销）：下一次检测间隔后重新认证一次；输错密码后不再自动重试。
11. 登录项开关可注册/注销；重启后菜单栏图标自动出现。
12. 重新打包一次 .app：观察定位授权与钥匙串是否被要求重新授权（ad-hoc 签名的预期行为）。

---

## 12. 已知限制（如实说明）

1. **物理合盖检测不是公开 API**：`IOPMrootDomain.AppleClamshellState` 属 IORegistry 属性，长期稳定但 Apple 未在文档中承诺；本应用只用它读 Bool，读不到时退化为"按睡眠通知判断"。检测粒度：事件即时 + 开盖时 10 秒 / 合盖后 30 秒低频兜底，因此"合盖但没睡眠"的**状态显示**最多延迟 10 秒；但**网络动作**不受这个延迟影响，因为每次动作前都会重新读盖子状态。
2. **SSID 读取受定位授权约束**：macOS 14+ 未授权时 `CWInterface.ssid()` 返回 nil。此时应用进入"权限问题"状态，绝不猜测网络身份、绝不认证。
3. **Wi-Fi 密码复用不确定**：`associate(to:password:)` 传 `nil` 时系统可能复用已保存凭据，也可能失败。因此宿舍网络建议在设置页显式保存密码（存本应用 Keychain），失败时状态会提示"缺少 Wi-Fi 密码"。
4. **`CWEventDelegate` 回调签名随 SDK 演进**：若某个事件在当前系统上不触发，`NWPathMonitor` 仍会在链路变化时唤醒评估；两条来源都做了防抖与去重。
5. **SRun 加密变体**：`info` 的 XXTEA 混合存在两种互不等价写法。默认 `reference`（与参考实现 AutoSZUWeb 一致），依据是：深澜前端 JS 的分步累加写法、以及独立第三方实现 `srunpy`（BUAA 部署）在同一输入下产出**逐字节相同**的密文；而官方 XXTEA 宏（`standard`）产出不同密文。独立验证向量记录在 `docs/TEST_REPORT.md`。若目标门户确实是官方写法，可在设置里切到 `standard`（两种都有已知答案测试）。
6. **校园协议可能不加密传输**：SRun 默认走 HTTPS，但部分部署/ ePortal 使用明文 HTTP。URL 编码不是加密；口令仍会以明文（ePortal）或 HMAC/XXTEA 形态（SRun）发给校内服务器。应用不关闭 TLS 校验，也不做证书钉扎。
7. **ad-hoc 签名的权限持久性**：重新构建后 TCC / Keychain 授权可能重置；未公证的包首次启动需手动放行（见 5.3）。
8. **不做窗口主界面**：只有菜单栏面板 + 设置窗口，符合"轻量菜单栏应用"的定位。

---

## 13. 安全与隐私

- 密码只存 Keychain（`kSecAttrAccessibleWhenUnlocked`），不写配置文件、不进日志、不经命令行参数。
- 日志写入前统一脱敏；认证 URL 不整体落盘。
- 保留系统默认 TLS 证书与主机名校验（与参考实现的差异见 `THIRD_PARTY_NOTICES.md`）。
- 认证请求只发往配置中的校内门户地址；不访问任何第三方分析/上报服务。
- 仓库内不含任何真实账号、密码、SSID 或 BSSID。

---

## 14. 许可

本项目 MIT（见 `LICENSE`）。第三方归属见 `THIRD_PARTY_NOTICES.md`。
