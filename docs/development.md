# 开发与验证

[返回项目首页](../README.md)

## 环境与源码

App 支持 macOS 14+。构建需 Swift 6 和包含 macOS 26 SDK 的 Xcode 26 或更新版本；
源码使用受系统版本检查保护的 Liquid Glass API。最近一次本机构建使用 Xcode 27.2。
项目使用本机 ad-hoc 签名，不需要 Apple Developer Program。

| 路径 | 用途 |
| --- | --- |
| `App/` | AppKit 菜单栏入口与 SwiftUI 界面（`Support/` 为主题与菜单栏渲染） |
| `Core/` | 额度模型、解析、安装检测与旧状态栏迁移；`Services/` 为各来源的数据读取，`Stores/` 为状态管理，`Support/` 为日期格式化 |
| `Tests/CoreTests/` | Swift Package 测试，覆盖 `Core/` 全部内容（含 Stores 与 Services） |
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
./script/run_probes.sh
./script/build_and_run.sh --preview
./script/build_and_run.sh --preview settings general light
./script/build_and_run.sh --render-preview en light codex
./script/build_and_run.sh --render-preview zh-Hans dark antigravity
./script/render_token_themes.sh en
```

`script/run_probes.sh` 依次编译并运行下文所列的隔离探针（不含 `--live` 和需要图形会话的滑块探针），
不读取真实账号、凭据或用户配置。
日期探针在独立进程中切换 TZ，检查本地重置/到期/查询时间、跨日及夏令时，不修改 Mac 系统时区。

GitHub Actions（`.github/workflows/ci.yml`）在每次推送和 PR 时于 macOS 26 runner 上执行
严格格式检查（`swift format lint --strict`）、`swift test`、Debug 构建、三张设计预览渲染、
`script/run_probes.sh` 和 Universal Release 打包，
并把预览 PNG 与 ad-hoc 签名的 ZIP 作为 7 天有效的构建产物上传。CI 不发布 Release，
也不代替原生界面与已安装 App 的验收。

代码格式由仓库根目录的 `.swift-format` 定义（4 空格缩进、每行 120 列），使用 Xcode 自带的 swift-format：

```bash
git ls-files -z '*.swift' | xargs -0 swift format --in-place --parallel
git ls-files -z '*.swift' | xargs -0 swift format lint --parallel
```

格式检查未通过时 CI 失败。可以运行上面的格式化命令，也可以在 GitHub Actions 中对该分支手动运行
Format 工作流（`.github/workflows/format.yml`），它会格式化全部 Swift 源码并把结果提交到该分支，
提交后仍需像其他改动一样审查。

`--preview` 支持面板与设置窗口；静态渲染结果位于 `build/qa/`，Codex 主题预览位于
`build/TokenThemePreview/`。部分原生控件不能通过 ImageRenderer 完整呈现，
玻璃材质、菜单和设置窗口需要原生窗口检查，不能用空白或占位图判定通过。

验收应分别记录源码/测试、构建产物、原生预览以及已安装 App 的结果。
预览使用模拟数据，不证明真实账户读取；进程存在或签名正确，也不证明已安装弹窗的视觉表现。
核对浅色、深色、中英文，以及受影响的菜单、选择和空数据状态。

可选 Codex 用量接口的隔离回归探针，不连接真实账户：

```bash
mkdir -p build
swiftc -parse-as-library Core/*.swift Core/Services/CodexBinaryLocator.swift \
  Core/Services/CodexAppServerClient.swift Tools/ClientFallbackProbe.swift \
  -o build/client-fallback-probe
for mode in silent eof unsupported usage launchFailure emptyCredits; do
  QUOTAI_PROBE_MODE=$mode build/client-fallback-probe || exit 1
done
```

Codex 命令发现的隔离回归探针，覆盖桌面版优先、旧路径、CLI 回退、自定义路径和符号链接去重，使用临时可执行文件：

```bash
swiftc -parse-as-library Core/*.swift Core/Services/CodexBinaryLocator.swift \
  Tools/CodexBinaryLocatorProbe.swift -o build/codex-binary-locator-probe
build/codex-binary-locator-probe
```

Antigravity 仅保留实时额度与账号模型权限链路，不再扫描本机 Token。
权限回归探针使用隔离偏好和注入响应，覆盖失败清除、权限未知、无权限回退、额度耗尽、恢复和迟到结果：

```bash
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library Core/*.swift \
  Core/Stores/QuotaProviderStore.swift Core/Stores/AntigravityUsageStore.swift \
  Core/Services/AntigravityQuotaClient.swift Core/Support/DateFormatting.swift \
  Tools/AntigravityQuotaFixtures.swift Tools/AntigravityQuotaProbe.swift -o /tmp/quotai-antigravity-probe
/tmp/quotai-antigravity-probe
```

原生 HTTP/HTTPS 与端点缓存回归使用本机合成服务，不读取真实账号；覆盖 IPv4/IPv6、自签名本机 TLS、拒绝重定向、响应上限、取消和缓存失效：

```bash
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library Core/*.swift \
  Core/Services/AntigravityQuotaClient.swift Tools/AntigravityTransportProbe.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker App/Info.plist \
  -o /tmp/quotai-transport-probe
python3 Tools/antigravity_transport_probe.py /tmp/quotai-transport-probe
```

加 `--live` 只读实际账号额度与权限分类，不输出认证或模型配置原文。
原生预览支持 `antigravity` 来源及 `available`、`denied`、`exhausted`、`unknown`、`missing`、`failed` 场景，
例如 `QUOTAI_BUILD_ROOT=/tmp/quotai-qa ./script/build_and_run.sh --preview panel general dark antigravity denied`。
Argon 独立周额度场景为 `argon`、`argon-denied`、`argon-unknown`、`argon-exhausted`、`argon-shared`；
可用于原生预览和 `--render-preview`。`argon-shared` 模拟没有独立池的账号，不新增 Argon 标签。
`QUOTAI_BUILD_ROOT` 可将构建、预览和打包产物放在项目外；未设置时保持原有 `build/` 路径。

Claude Code 当前使用官方 CLI `/usage` 查询；保留旧状态栏辅助程序用于安全退役和配置恢复。
查询探针用隔离子进程覆盖套餐首次读取、重启读回、换套餐/退出登录、空窗口清除旧缓存、超时、取消、输出上限和迟到结果；不会修改真实用户配置。
`--live` 则明确执行一次真实 `/usage` 与 `auth status`，只输出解析后的额度和套餐，不保存原始结果。
`--live-subscription` 仅查询真实登录的套餐，不查询额度。

```bash
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library Core/*.swift \
  Core/Stores/QuotaProviderStore.swift Core/Stores/ClaudeCodeUsageStore.swift \
  Core/Services/ClaudeUsageQueryClient.swift Tools/ClaudeUsageQueryProbe.swift \
  -o build/claude-usage-query-probe
build/claude-usage-query-probe
build/claude-usage-query-probe --live
build/claude-usage-query-probe --live-subscription
./script/build_and_run.sh --render-preview zh-Hans dark claude recent
./script/build_and_run.sh --preview panel general dark claude recent
./script/build_and_run.sh --render-preview en light claude weekly
./script/build_and_run.sh --render-preview zh-Hans dark claude inactive
```
数据与迁移边界见[数据来源与隐私](data-sources.md)。

## 打包与发布

应用图标母版为 `Design/AppIcon-master.png`，界面标识沿用同一图形。
修改母版后运行 `./script/generate_app_icons.sh`，将母版及生成的全部 asset 资源一同提交，再打包。

```bash
./script/build_and_run.sh --package-release
```

生成的 Universal Release ZIP 位于 `build/Distribution/`，支持 Apple Silicon 和 Intel；
脚本验证 ad-hoc 签名并输出 ZIP 路径与 SHA-256，不执行安装或公开发布。
同营销版本可以有不同构建号，核对包内 `Info.plist`、可执行文件哈希和架构，不能只看 ZIP 文件名。

`script/verify_and_release.sh <版本> --check-only` 执行测试、Debug 构建、隔离探针和打包检查。
去掉 `--check-only` 会提交全部工作区改动、打标签、推送并创建 GitHub Release；
工作区没有未提交改动时（例如改动已通过 PR 合入）跳过提交，直接为当前提交打标签；
正式发布前需要审查工作区差异、版本说明和发布动作。
脚本依赖 `Design/release-notes-<版本>.md`。本地修复、构建或文档整理均不等于发布授权。

滑块连续性探针（需要已解锁的 macOS 图形会话；使用独立小窗口，不访问真实偏好或业务数据）：

```bash
mkdir -p /tmp/quotai-picker-motion
xcrun swiftc -parse-as-library -target arm64-apple-macosx14.0 \
  App/Support/AppTheme.swift App/Views/PickerSelectionBackground.swift \
  Tools/PickerContinuityProbe.swift -o /tmp/quotai-picker-motion/probe \
  -framework AppKit -framework SwiftUI -framework QuartzCore
/tmp/quotai-picker-motion/probe /tmp/quotai-picker-motion/result.json
```

探针检查呈现图层在连续布局、高度变化和中途反向切换时的运动连续性，以及减少动态效果下即时到位。
它不代替正式弹窗的交互与观感验收。

当前版本的测试、构建和安装状态以[版本说明](../Design/release-notes-3.0.3.md)为准，
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


## 3.0 架构与可选功能

`QuotAIAppModel` 持有稳定的 `QuotaProviderRegistry`、Store 与可选功能控制器。AppDelegate、面板与设置统一从注册表解析来源及刷新目标。实现 `QuotaProviderPlugin`，提供 descriptor、独立 Store、生命周期和 `ProviderQuotaSnapshot` 后即可注册；新的适配器默认复用通用额度视图及菜单栏/通知/趋势/小组件投影。注册表验证重复 ID，Codex 为保留回退；原有持久化 ID 与设置键保持不变。这里的插件是编译期适配模块，不加载第三方二进制或脚本。

`Core` 是 SPM 可测试 target，包含 Services/Stores/Support/Features/Widget 的无 UI 数据层。`App` 仅负责原生桥接与视图，WidgetKit 扩展只编译共享快照、私有文件写入、共用额度视图和本地化。新增源文件可运行 `python3 script/configure_platform_targets.py`，脚本幂等同步工程及平台 target；版本更新必须同时修改 App/Widget 的版本，打包验证会检查一致性。

### 签名、小组件与更新

Sparkle 固定为 2.9.6，并提交 `Package.resolved`。CI 无需发布密钥，生成 ad-hoc 包并检查 app/extension 通用架构、版本与所有嵌套签名；ad-hoc 构建不支持团队 App Group。正式团队签名可通过 `QUOTAI_SIGN_IDENTITY` 与 `QUOTAI_SIGN_TEAM` 传给 `--package-release`，App 与扩展的 App Group 使用 `<TEAMID>.com.willhsu.QuotAI`。

本机独立 QA：`./script/build_signed_qa.py` 使用已有 Apple Development 身份，产物位于 `build/SignedQA/`。QA Bundle ID、URL scheme 与 App Group 独立，并始终使用合成 Store、跳过真实 CLI 配置迁移；启动加 `--qa-widget --qa-shortcut` 可验证共享容器与快捷键。其签名不代表 Developer ID 分发或公证。

`./script/build_and_run.sh --render-widget en light medium fresh` 以及 `... zh-Hans dark small expired` 渲染扩展使用的同一个内容组件，不能替代系统桌面宿主验证。

`./script/prepare_update.py <archive.zip>` 验证实际包、匹配内置公钥后，使用官方 Sparkle 工具从 `com.willhsu.QuotAI` 钥匙串条目签名并立即验证，只输出候选 feed，不上传、不导出私钥、不修改 git。默认工具目录为 `build/SparkleSDK/distribution/bin`，可用 `SPARKLE_BIN` 覆盖。只从官方 Sparkle 2.9.6 发行页获取工具。先上传并核验 archive，再通过评审提交将候选 feed 提升到 `Updates/appcast.xml`，防止更新源先于资源生效。

`verify_and_release.sh <version>` 默认仅验证；只有显式 `--publish` 才打 tag、推送并发布。发布要求工作树已干净且意图变更已提交，脚本不会执行 `git add -A` 或代提交其他修改。首次安装仍走现有手动分发流程，2.x 没有 Sparkle；3.0 之后的已签名版本可通过应用内更新。Developer ID/公证与另一台 Mac 的 Gatekeeper 验收需要单独完成。
