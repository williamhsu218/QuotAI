# 开发与验证

[返回项目首页](../README.md)

## 环境与源码

App 支持 macOS 14+。构建需 Swift 6 和包含 macOS 26 SDK 的 Xcode 26 或更新版本；
源码使用受系统版本检查保护的 Liquid Glass API。最近一次构建使用 Xcode 27.0。
项目使用本机 ad-hoc 签名，不需要 Apple Developer Program。

| 路径 | 用途 |
| --- | --- |
| `App/` | AppKit 菜单栏入口、SwiftUI 界面、数据源服务和状态管理 |
| `Core/` | 额度模型、Codex 用量解析、安装检测和旧状态栏迁移 |
| `Tests/CoreTests/` | Swift Package 核心测试 |
| `Preview/`、`Tools/` | 隔离预览、渲染器和诊断探针 |
| `Resources/` | 英文与简体中文资源 |
| `Assets.xcassets/`、`Design/` | 生产素材、有效主稿和当前版本说明 |
| `script/` | 构建、预览、打包及发布入口 |

## 构建与运行

所有命令从项目根目录执行。只构建而不影响已运行的 App：

```bash
xcodebuild -project QuotAI.xcodeproj -scheme QuotAI -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

构建并运行开发版：

```bash
./script/build_and_run.sh
```

该脚本的默认、`--debug`、`--logs`、`--telemetry` 和 `--verify` 模式会先结束正在运行的
QuotAI，再启动开发构建。产物位于 `build/DerivedData/Build/Products/Debug/QuotAI.app`，
不会自动替换 `/Applications/QuotAI.app`。

## 测试与界面检查

```bash
swift test
./script/build_and_run.sh --preview
./script/build_and_run.sh --preview settings general light
./script/build_and_run.sh --render-preview en light codex
./script/build_and_run.sh --render-preview zh-Hans dark antigravity
./script/render_token_themes.sh en
```

`--preview` 支持面板与设置窗口；静态渲染结果位于 `build/qa/`，Codex 主题预览位于
`build/TokenThemePreview/`。部分原生控件不能通过 ImageRenderer 完整呈现，
玻璃材质、菜单和设置窗口需要原生窗口检查，不能用空白或占位图判定通过。

验收应分别记录源码/测试、构建产物、原生预览以及已安装 App 的结果。
预览使用模拟数据，不证明真实账户读取；进程存在或签名正确，也不证明已安装弹窗的视觉表现。
核对浅色、深色、中英文，以及受影响的菜单、选择和空数据状态。

可选 Codex 用量接口的隔离回归探针，不连接真实账户：

```bash
mkdir -p build
swiftc -parse-as-library Core/*.swift App/Services/CodexBinaryLocator.swift \
  App/Services/CodexAppServerClient.swift Tools/ClientFallbackProbe.swift \
  -o build/client-fallback-probe
for mode in silent eof unsupported usage launchFailure; do
  QUOTAI_PROBE_MODE=$mode build/client-fallback-probe || exit 1
done
```

Codex 命令发现的隔离回归探针，覆盖桌面版优先、旧路径、CLI 回退、自定义路径和符号链接去重，使用临时可执行文件：

```bash
swiftc -parse-as-library Core/*.swift App/Services/CodexBinaryLocator.swift \
  Tools/CodexBinaryLocatorProbe.swift -o build/codex-binary-locator-probe
build/codex-binary-locator-probe
```

Antigravity 仅保留实时额度链路，不再提供本机 Token 扫描、专用 Probe 或 Token 预览模式。
Claude Code 当前使用官方 CLI `/usage` 查询；保留旧状态栏辅助程序用于安全退役和配置恢复。
查询探针用隔离子进程覆盖超时、取消、输出上限和迟到结果；不会修改真实用户配置。
`--live` 则明确执行一次真实 `/usage`，只输出解析后的额度，不保存原始结果。

```bash
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library Core/*.swift \
  App/Stores/QuotaProviderStore.swift App/Stores/ClaudeCodeUsageStore.swift \
  App/Services/ClaudeUsageQueryClient.swift Tools/ClaudeUsageQueryProbe.swift \
  -o build/claude-usage-query-probe
build/claude-usage-query-probe
build/claude-usage-query-probe --live
./script/build_and_run.sh --render-preview zh-Hans dark claude recent
./script/build_and_run.sh --preview panel general dark claude recent
```
数据与迁移边界见[数据来源与隐私](data-sources.md)。

## 打包与发布

```bash
./script/build_and_run.sh --package-release
```

生成的 Universal Release ZIP 位于 `build/Distribution/`，支持 Apple Silicon 和 Intel；
脚本验证 ad-hoc 签名并输出 ZIP 路径与 SHA-256，不执行安装或公开发布。
同营销版本可以有不同构建号，核对包内 `Info.plist`、可执行文件哈希和架构，不能只看 ZIP 文件名。

`script/verify_and_release.sh <版本> --check-only` 执行测试和打包检查。
去掉 `--check-only` 会提交全部工作区改动、打标签、推送并创建 GitHub Release；
正式发布前需要审查工作区差异、版本说明和发布动作。
脚本依赖 `Design/release-notes-<版本>.md`。本地修复、构建或文档整理均不等于发布授权。

当前版本的测试、构建和安装状态以[版本说明](../Design/release-notes-2.1.1.md)为准，
不能沿用旧版本的验收结果。

ad-hoc 签名没有 Apple Developer ID 或公证。可信安装包经浏览器等途径传输后可能带隔离标记。
若无法打开，先将 App 移入“应用程序”，确认来源后执行：

```bash
xattr -dr com.apple.quarantine "/Applications/QuotAI.app"
open "/Applications/QuotAI.app"
```

## 文档与本地文件保留

- 当前使用方式、开发命令、数据口径、设计规则分别维护在首页和 `docs/`，避免按每次构建新增说明。
- `Design/` 仅保留有效主稿与当前版本说明；旧 QA、设计过程和已发布版本说明可从 Git 历史追溯。
- `build/` 是生成物，不提交。过期 DerivedData、下载包、旧截图和旧应用副本可清理；清理前检查进程是否使用它们。
- 保留当前版本及验收记录、一个明确的应用回滚版本；更新后核对签名、包内容和用户偏好。
- 真实数据库、缓存和偏好快照不是可再生构建缓存。`build/InstallBackups/` 及各验收目录内的此类文件应单独保留，不随旧应用包删除。
- `.build/` 是 Swift Package 开发缓存，`.git/` 保存项目历史；它们不属于过时文档。
- 不将凭据、对话或真实数据写入项目文档。需要记录故障时保留脱敏结论和定位方法。
