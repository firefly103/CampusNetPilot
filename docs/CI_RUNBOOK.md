# CI 运行手册（GitHub Actions）

目标：在 macOS runner 上编译、测试、组装 arm64 `.app`、ad-hoc 签名并产出可下载 zip。

## 0. 前置条件（缺一不可）

| 项 | 检查命令 | 说明 |
|---|---|---|
| GitHub 仓库 | `git remote -v` | 当前目录**不是** git 仓库时，`remote -v` 会报 `not a git repository` |
| 推送凭据 | `git push --dry-run` | 需要 HTTPS PAT 或已在 GitHub 注册的 SSH key（`ssh -T git@github.com` 返回 `Hi <user>!`） |
| 工作流文件 | `ls .github/workflows/build.yml` | 已随仓库提供，`workflow_dispatch` 已开启 |

## 1. 创建仓库并推送（约 3 分钟）

在 GitHub 网页新建一个**空**仓库（不要勾选 README / .gitignore / license），然后在项目目录执行：

```bash
git init -b main
git add -A
git commit -m "CampusNetPilot: macOS 校园网自动认证与 Wi-Fi 切换"
git remote add origin git@github.com:<你的账号>/CampusNetPilot.git   # 或 https://github.com/<账号>/CampusNetPilot.git
git push -u origin main
```

> 用 HTTPS 时，push 会要求用户名 + Personal Access Token（`repo` 权限）。

推送后 `build` 工作流会自动触发（`push` 到 `main`）。

## 2. 手动触发 / 查看日志

```bash
# 需要在装有 gh 并已 gh auth login 的机器上
gh workflow run build.yml
gh run list --workflow=build.yml --limit 3
gh run watch <RUN_ID>
gh run view <RUN_ID> --log-failed
```

没有 `gh` 就在网页：**Actions → build → Run workflow**，点进本次 run 看每一步日志。

## 3. 取回产物

```bash
gh run download <RUN_ID> -n CampusNetPilot-macos-arm64 -D dist/
shasum -a 256 -c dist/CampusNetPilot-*.zip.sha256
unzip -q dist/CampusNetPilot-*.zip -d /Applications/
```

网页：run 页面底部 **Artifacts → CampusNetPilot-macos-arm64**（zip + `.sha256`，保留 30 天）。

## 4. 失败时的最小反馈内容

把以下三样贴回来即可定位（无需整段日志）：

1. run 链接（含 commit SHA，形如 `.../actions/runs/123456`）；
2. 失败 step 的名字（`环境自检` / `运行核心逻辑测试` / `构建 .app` / `校验产物结构`）；
3. 该 step 的最后 40 行日志，或 artifact `test-log`。

常见原因与对应处理：

| 现象 | 处理 |
|---|---|
| `环境自检` 报 SDK < 14 | runner 镜像不对，确认 `runs-on: macos-15` |
| `swift test` 失败 | 核心逻辑问题，本地 `swift test` 复现（Linux/macOS 均可） |
| `build-app.sh` 编译失败 | macOS 专属源码（SwiftUI/CoreWLAN/IOKit）问题，看 `error:` 行 |
| `codesign` 失败 | 确认没有启用 `--deep`、没有空 entitlements；ad-hoc 用 `--sign -` |
| `lipo` 不是 arm64 | runner 架构不对，`macos-15` 应为 arm64 |
| artifact 为空 | 检查 `dist/*.zip` 是否生成（`build-app.sh` 末尾输出） |
