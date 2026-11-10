# 第三方作品与许可说明

本项目为全新 Swift 实现，**没有复制下列项目的源代码**。参考范围仅限协议流程、
架构思路与交互设计；所有 Swift 代码均按 Apple 官方文档（CoreWLAN / IOKit /
SwiftUI / Security / ServiceManagement）重新编写。

许可证与 API 适用性核实时间：2026-11-10，通过 GitHub REST API 读取仓库元数据。

| 项目 | 许可证 | 参考了什么 | 是否复制代码 |
|---|---|---|---|
| [ATMLuck/AutoSZUWeb](https://github.com/ATMLuck/AutoSZUWeb) | MIT | 深大 SRun（`get_challenge` → XXTEA+定制 Base64 `info` → SHA1 `chksum` → `srun_portal`）与 ePortal 的请求顺序、成功判定、失败分类；凭据保护与按天日志思路 | 否，按协议重写为 Swift（`Sources/CampusNetCore/Auth.swift`、`Crypto.swift`） |
| [coderask/auto-wifi](https://github.com/coderask/auto-wifi) | 仓库未提供 LICENSE 文件 | CoreWLAN 扫描/关联流程、权限处理、避免反复切换的设计 | 否（未提供许可证，仅参考公开的设计思路，不复制代码） |
| [metacometdave/SleepWatch](https://github.com/metacometdave/SleepWatch) | MIT | 睡眠/唤醒事件处理方式 | 否；其"合盖关闭 Wi-Fi/蓝牙"的行为**明确未采用**（本应用不改动系统无线状态） |
| [Johnny-Kao/Wi-Fi-Auto-Switching-Tool](https://github.com/Johnny-Kao/Wi-Fi-Auto-Switching-Tool) | 仓库未提供 LICENSE 文件 | 已知网络配置 → 扫描 → 切换的流程 | 否；其"按信号强度选网"的策略**明确未采用**（本应用使用固定优先级） |

## 验证用对照实现（未进入仓库）

`docs/TEST_REPORT.md` 记录了一次独立交叉验证：在构建机临时安装 PyPI 上的
`srunpy` 1.1.0.1（面向 BUAA 深澜网关的第三方实现），用同一输入比对 `xEncode` 密文，
确认本项目的 `reference` 变体与其逐字节一致。该包**没有被复制、vendor 或链接**，
只是作为"已知答案"的对照来源；复现命令见测试报告。

## 协议来源说明

SRun 的 `xEncode`（XXTEA 变体）、定制 Base64 字母表
`LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA`、
`chksum` 拼接口径均属于深澜门户的**公开协议行为**，不是 AutoSZUWeb 的独创代码；
本项目按其公开流程独立实现，并用 `tools/srun_reference.py` 生成已知答案测试向量。

与参考实现的两处**有意差异**：

1. 参考实现为兼容自签证书关闭了 TLS 校验；本项目保留系统默认的证书与主机名校验。
2. 参考实现每个周期无条件探测+认证；本项目由状态机按需触发，并在提交前再次校验 SSID。

## 商标

"CampusNetPilot"、"校园网助手"为本项目名称。深圳大学、SRun、ePortal 等名称与商标
归各自权利人所有，本项目与其无隶属关系。

## MIT 许可正文（适用于本项目自身）

见仓库根目录 `LICENSE`。
