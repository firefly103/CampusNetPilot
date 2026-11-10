# 测试执行报告

执行环境（本次交付）：

| 项 | 值 |
|---|---|
| 主机 | Windows 11 (x86_64)，无 Xcode、无 macOS |
| 执行位置 | WSL2 Ubuntu 24.04 |
| Swift 工具链 | Swift 6.0.3-RELEASE (x86_64-unknown-linux-gnu) |
| 被测目标 | `CampusNetCore`（协议无关核心：配置、状态机、SRun 协议、探测、日志） |
| 命令 | `swift build` / `swift test` |

> 说明：**Windows 上无法编译 SwiftUI / CoreWLAN / IOKit**，所以这里执行的是"不依赖
> 苹果框架"的核心逻辑测试。macOS 端的编译、.app 组装与签名由
> `.github/workflows/build.yml`（macos-15 runner）完成，不能把本报告当作 macOS 构建通过的证明。

## 最近一次运行结果

```
Test Suite 'CryptoTests'          passed   13 tests
Test Suite 'ConfigTests'          passed   11 tests
Test Suite 'AuthClientTests'      passed    7 tests
Test Suite 'EngineScenarioTests'  passed   33 tests
Test Suite 'ProbeTests'           passed    4 tests
Test Suite 'All tests'            passed   68 tests, 0 failures
```

## 覆盖矩阵（对应需求第九节 14 条验收项）

| # | 验收要求 | 对应用例 | 结果 |
|---|---|---|---|
| 1 | 合盖后停止产生新扫描、探测、认证 | `EngineScenarioTests.testLidClosedStopsProbingAndScheduling` | 通过 |
| 2 | 合盖前启动的任务不会在合盖后继续触发操作 | `testInFlightScanResultDiscardedAfterLidClose`（用 Gate 卡住扫描，合盖后再放行） | 通过 |
| 3 | 开盖已连白名单：零扫描/探测/认证 | `testOpenLidOnWhitelistIsCompletelySilent` | 通过 |
| 4 | 校园网 + 宿舍可见：扫描一次 → 切换 → 静默 | `testCampusWithDormVisibleSwitchesOnceThenSilent` | 通过 |
| 5 | 校园网 + 宿舍不可见：扫描后按需认证，默认不周期扫描 | `testCampusWithoutDormScansThenAuthenticatesOnce` | 通过 |
| 6 | 切换失败不循环跳网 | `testSwitchFailureDoesNotLoop`（含 90s 冷却后允许再次定时扫描） | 通过 |
| 7 | 已在线：不重复登录 | `testCampusOnlineDoesNotLoginAgain` | 通过 |
| 8 | 认证失效：按需重新认证 | `testSessionExpiryTriggersReauthentication` | 通过 |
| 9 | 手动切到白名单/其他网络：任务停止、旧结果作废 | `testSwitchingToWhitelistStopsCampusWork`、`testUnknownNetworkStaysSilentAndNeverAuthenticates` | 通过 |
| 10 | 同 SSID 漫游 / 重复唤醒 / 快速开合盖不重复触发 | `testSameSSIDRoamingDoesNotRescan`、`testDuplicateLidNotificationsAreIdempotent` | 通过 |
| 11 | 定时扫描默认关闭，开关与状态切换正确管理定时器 | `testPeriodicScanToggleManagesTimer` | 通过 |
| 12 | Wi-Fi 关闭 / 权限不足 / SSID 不可读 / 接口缺失 / 扫描失败 / 密码错误 | `testWiFiOffIsRespected`、`testSSIDUnreadableBlocksEverything`、`testInterfaceUnavailableIsReported`、`testScanFailuresAreBounded`、`testPasswordErrorStopsRetries`、`testMissingCredentialsBlockAuthentication` | 通过 |
| 13 | 后台维护唤醒且盖子仍关闭：不扫描不认证 | `testMaintenanceWakeWithLidClosedStaysPaused` | 通过 |
| 14 | 开盖但仅熄屏/锁屏：不被误判为合盖，且继续校园网监控 | `testScreenOffWithLidOpenKeepsMonitoring`、`testConnectivityTimerStillRunsWhileDisplayIsOff` | 通过 |
| 15 | 合盖但未睡眠（外接显示器）时不得漏发认证 | `testLidClosedBeforeScanAbortsEverything`、`testLidClosedMidFlowAbortsAuth` | 通过 |
| 16 | 重复网络事件不得反复取消认证 | `testRepeatedNetworkEventsDoNotCancelInFlightAuth`（Gate 卡住认证，连发 3 次同 SSID 事件后仍只认证一次） | 通过 |
| 17 | 同 SSID 的真实连接变化必须重新评估 | `testSameSSIDIPChangeTriggersReevaluation`、`testSameSSIDInterfaceChangeTriggersReevaluation`、`testDisconnectReconnectSameSSIDReevaluates` | 通过 |
| 18 | 同 SSID 漫游不得取消进行中的认证 | `testRoamingBSSIDChangeDoesNotCancelAuth` | 通过 |

## 协议与配置层

| 用例 | 断言内容 |
|---|---|
| `CryptoTests.testMD5KnownVectors` / `testSHA1KnownVectors` / `testHMACMD5RFC2202Case1` | 纯 Swift 摘要实现与标准向量一致（MD5 `abc`、SHA1 `abc`、RFC 2202 case 1） |
| `testXEncodeReferenceVariant` / `testXEncodeStandardVariant` / `testXEncodeVariantsDiffer` | 两种 XXTEA 混合写法各自的已知答案，且两者确实不同（避免"看起来实现对了"） |
| `testInfoPayload` / `testChecksum` / `testPasswordDigest` | `{SRBX1}+Base64` info、SHA1 chksum、HMAC-MD5 密码摘要与 Python 参考实现逐字节一致 |
| `AuthClientTests.testSRunLoginFlow` | 三次请求顺序（首页→challenge→portal）、`ac_id` 提取、`password={MD5}…` 不含明文、info/chksum 与服务端参数一致 |
| `testSRunBadPasswordIsClassified` / `testSRunChallengeErrorIsReported` / `testSRunNetworkFailureIsNetworkKind` | 失败分类：密码错误 / 门户拒绝 / 网络错误 |
| `testEPortalLoginFlow` / `testEPortalMissingURL` / `testDisabledModeSendsNothing` | ePortal 请求构造与缺配置时零请求 |
| `ProbeTests.*` | 204 与 "Success" 判在线；重定向判门户拦截；全部端点传输层失败才判离线 |
| `ConfigTests.*` | 宿舍网络自动并入白名单、校园 SSID 优先、精确匹配、优先级不按信号、间隔钳制、损坏配置回退、示例配置不含密码 |

## 已知无法在本环境验证的项（必须真机）

1. CoreWLAN 的 SSID 读取在目标 macOS 上是否需要定位授权、授权后是否立即生效。
2. `CWInterface.associate(to:password:)` 在 M3 + 目标 macOS 上对 WPA2/WPA3 个人网的实际行为，
   以及 `password: nil` 时能否复用系统已保存凭据。
3. `IOPMrootDomain.AppleClamshellState` 在"M3 + 外接显示器合盖不睡"场景下的取值时序。
4. 真实 SRun / ePortal 认证是否成功（含 XXTEA 变体选择）。
5. ad-hoc 签名下 TCC（定位）与 Keychain ACL 是否在重新打包后被重置。
6. `SMAppService` 登录项在未签名/临时目录下的注册结果。

这些项的处理方式与风险已在 README「待真机验证清单」「已知限制」中逐条列出。

## XXTEA 变体：默认选择依据与独立验证

`srun` 的 `xEncode` 混合步骤有两种互不等价的写法，必须明确默认值与证据：

| 写法 | 形态 | 本项目取值 |
|---|---|---|
| `reference` | 分步累加：`m = (z>>5 ^ y<<2); m += ((y>>3 ^ z<<4) ^ (sum ^ y)); m += (k ^ z)` | **默认** |
| `standard` | Wheeler/Needham 官方宏：`(A + B) ^ ((sum ^ y) + D)` | 仅作为可切换的兜底 |

选择依据（三条独立证据）：

1. 参考实现 `ATMLuck/AutoSZUWeb`（MIT，深圳大学实际在用）的 `src/srun.cpp` 使用分步累加写法；
2. 深澜前端 JS 的 `xEncode` 同样是分步累加；
3. **独立第三方实现交叉验证**：`srunpy` 1.1.0.1（PyPI，面向 BUAA `gw.buaa.edu.cn` 的实现，与本项目无共同来源）在以下输入上产出与本项目 `reference` **逐字节相同**的密文，而 `standard` 不同：

```
payload   = {"username":"2024000000","password":"p@ss w0rd!","ip":"10.20.30.40","acid":"1","enc_ver":"srun_bx1"}
key       = challenge-0123456789abcdef

srunpy  get_xencode(...).encode("latin-1").hex()
        = b81de52e11df117a33170385dc036e53c53aa4380cf722ccba5d84294fa11751
          fe8a55ce5c64a088d79e93975b9a58bb9a51e2a6b8e39b3997dba84b87be98a5
          93a6e602a45d855afbe841e6850027588df43a0f29ab9e0203232d2eef30636f
          b65ea4e4b28a0d28
本项目 reference   : 同上（完全一致）
本项目 standard    : 8351e6d3...c65971（不一致）

对应 Base64（SRun 字母表）：KV7pGTNsPc/zivyi7L0KH4HB3JS95xG9KpIP8HQTijNQXpcycCmSX0rrYenWUpXEUpNX3lkkUzUcIBTGTEBZ31yUeS8YcZuOQQTVe/HLRjX05J/g8OKrLS9kGmEw9C0wfpBYeG88JmS=
```

复现方式（不需要安装任何依赖）：

```bash
python3 -m venv /tmp/venv && /tmp/venv/bin/pip install srunpy==1.1.0.1
/tmp/venv/bin/python - <<'PY'
import srunpy.srun as S
p='{"username":"2024000000","password":"p@ss w0rd!","ip":"10.20.30.40","acid":"1","enc_ver":"srun_bx1"}'
print(S.get_xencode(p, "challenge-0123456789abcdef").encode("latin-1").hex())
PY
python3 tools/srun_reference.py   # 打印本项目参考实现的同一向量
```

注：`srunpy` 只作为**验证用的对照实现**在构建机临时运行，未进入本仓库、未参与产品代码。