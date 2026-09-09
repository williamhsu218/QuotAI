# QuotAI

macOS 原生菜单栏工具。把本机 Codex 与 Antigravity 额度放在同一个工具中，
但保持独立读取、独立状态和独立界面：

- 5 小时剩余额度；Codex 暂不返回该窗口时整行隐藏
- 7 天剩余额度
- Codex Token 累计用量、连续活跃天数及最近 18 周活跃度；需要本机 Codex 支持可选的 `account/usage/read` 接口
- Antigravity 的 Gemini 与 Claude/GPT 模型组使用居中的两个标签切换；每组分别展示 5 小时与每周额度，
  不与 Codex 或另一个 Antigravity 模型组相加
- Antigravity 本机 Token 实验统计：输入＋输出（含思考）＋缓存命中总量，三项明细、模型汇总及最近 18 周日期方格统一以 M 显示；只在打开 Antigravity 面板或手动点击时限量读取
- 弹窗使用 Codex / Antigravity 两个明确页面；菜单栏可在设置中选择 Codex 或
  某个 Antigravity 模型组
- 菜单栏继续复用原有“仅 5h / 仅 7d / 同时显示”偏好，升级后不会重置当前选择
- 当前 ChatGPT 套餐名称；优先取自额度响应，缺失时回退到本机账户响应
- 各额度窗口的北京时间重置时间
- 可用重置卡数量与每张卡的北京时间过期时间
- 内置 Stay Awake（Caffeine）功能，可选择“Mac 不休眠、显示器可息屏”或“Mac 与显示器均保持唤醒”，并支持 5/10/15/30 分钟、1/2/5 小时或无限期
- English 与简体中文；跟随 macOS 系统语言或“App Language”设置
- macOS 26+ 使用原生 Liquid Glass 面板与玻璃按钮；macOS 14–15 自动回退为系统材质
- 菜单栏入口由 AppKit `NSStatusItem` 持有，不受 SwiftUI 菜单项“已移除”状态影响
- 左键打开额度面板；右键使用原生窄版菜单快速切换 Stay Awake、立即刷新当前菜单栏 Provider 或打开设置
- 深色青绿 Q 标 App Icon 与透明 HUD Mark，包含完整 macOS 16–1024 px 尺寸集

## 本地运行

要求 macOS 14+、Xcode 16+。读取 Codex 时需确保本机 ChatGPT/Codex 已登录；
读取 Antigravity 时需确保 Antigravity 已登录并正在运行。

```bash
./script/build_and_run.sh
```

程序是 `LSUIElement` 菜单栏 App，不显示 Dock 图标。构建后的 App 位于：

```text
build/DerivedData/Build/Products/Debug/QuotAI.app
```

常用验证命令：

```bash
swift test
./script/build_and_run.sh --verify
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --render-preview
./script/build_and_run.sh --render-preview zh-Hans dark antigravity
./script/build_and_run.sh --package-release
```

可选 Token 接口的隔离回归测试（不连接真实账户）：

```bash
mkdir -p build
swiftc -parse-as-library Core/*.swift App/Services/CodexBinaryLocator.swift App/Services/CodexAppServerClient.swift Tools/ClientFallbackProbe.swift -o build/client-fallback-probe
for mode in silent eof unsupported usage; do
  QUOTAI_PROBE_MODE=$mode build/client-fallback-probe || exit 1
done
```

`--package-release` 会生成不含调试文件的 Universal Release ZIP，同时支持
Apple Silicon 与 Intel。由于 App 使用 ad-hoc 签名而非 Apple Developer ID，
通过微信、浏览器等方式传输后 macOS 会添加隔离标记。如果双击无法打开，先将
App 移到“应用程序”，再运行：

```bash
xattr -dr com.apple.quarantine "/Applications/QuotAI.app"
open "/Applications/QuotAI.app"
```

这一步不需要管理员密码，但只应对可信来源的 App 执行。若希望接收者无需此步骤，
则必须使用 Developer ID 签名并完成 Apple 公证。

如果安装了 Bartender 等菜单栏管理工具，请在该工具中把 QuotAI 设置为
始终显示；此类工具可以在 App 已正常创建状态项后继续将它放入隐藏区。

## 数据与隐私

App 通过本机 `codex app-server --stdio` 的 `account/rateLimits/read` 读取 Codex
额度与套餐名称，不上传数据，也不保存登录令牌、账号 ID 或邮箱。最近一次成功的
Codex 额度、套餐名称与 Token 用量仅缓存在本机 Application Support 目录。
可选的 `account/usage/read` 失败或超时不影响额度读取；暂时缺失时保留最近缓存，
接口明确返回空用量时清除旧图表。Token 数据为账户接口统计，不代表本 App 产生的用量。

Antigravity 使用另一条完全独立的本机链路：运行时发现其动态 language-server
监听端口，并调用
`exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`。瞬时本地
CSRF 信息只在单次刷新内驻留内存；Antigravity 额度、认证信息和账户明细不会写入
缓存或日志。该 RPC 是当前 Antigravity 2.8.1 已验证、但未公开承诺稳定的内部接口；
Antigravity 未运行或协议变化时，App 显示“不可用”，不会显示成 0，也不会回退为
Codex 额度。

从 Finder 启动时，App 会保留已有的 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、
`CODEX_CA_CERTIFICATE` 和 `SSL_CERT_FILE`，并在未设置代理环境变量时读取 macOS
系统的 HTTP、HTTPS 或 SOCKS 代理，再传给 `codex app-server`。代理地址和证书路径
不会写入日志。

App 会依次尝试本机 Codex CLI、PATH 中的 Codex 和 ChatGPT 内置 Codex，并选择首个
能够返回额度的版本。额度仅适用于 ChatGPT Codex 登录；API Key 登录不包含 ChatGPT
订阅额度。若本机所有 Codex 版本都不支持 `account/rateLimits/read`，App 会提示更新
ChatGPT 或 Codex CLI。

本项目面向个人本机使用，构建脚本采用无开发者账号签名的本地构建方式，不需要 Apple Developer Program。

### Antigravity 本机 Token 统计

统计源为 `~/.gemini/antigravity/conversations/*.db` 内的 `gen_metadata`，
日期来自按主键关联的 `steps.metadata`。独立于额度 RPC 和 Codex，不读取 `steps.step_payload`、
会话标题、工作区路径或聊天正文。不调用模型、网络、CLI 子进程，也不新增定时器或文件监听。

- 每次按需请求最多处理 4 个会话、512 条元数据（生成与关联步骤共用）、768 KiB；读取循环与 SQLite 查询设 80 ms 工作预算。每次生成最多查一个步骤，不全表扫描。准备与缓存汇总时间另计，不承诺整机绝对零开销。
- 初次历史较多时显示部分统计，可点卡片右上角刷新图标继续读取；不会自动在后台补齐。
- 安全上限为 512 个会话库、10 万条缓存元数据记录，超限保留部分状态，不启动无界历史扫描。
- 未变化的源数据库跳过。变化文件按主键分批重校，覆盖追加、旧记录修改、撤回和删除；使用响应标识的 SHA-256 去重，冲突或无法识别的记录不计入并标注。
- 缓存位于 Application Support/QuotAI/AntigravityTokens/metadata-v2.sqlite，只有数值、验证后的时间戳、模型家族、哈希和读取进度；不保存原始响应或执行标识、元数据。连接用完即关。旧 v1 候选曾把模型编号误算为输入 Token，v2 不复用旧值，按需重新读取，不删除旧缓存。
- 仅只读访问源库，遇锁立即跳过；运行中的 WAL 数据库绝不使用 immutable。离线 WAL 库无 sidecar 时，须确认没有 Antigravity/language_server 进程，且读取前后文件指纹不变，才接受只读结果。
- 显示的是**本机保留会话的已记录用量**，不是账户全设备总量或账单。总量使用 ModelUsageStats 输入 #2 ＋ 输出 #3 ＋ 缓存命中 #5，三项分别展示；#1 为模型编号不计入，输出已含思考，不再叠加思考或缓存写入。
- 总量、模型汇总和日期格采用同一含缓存命中口径，统一以 M（百万 Token）显示两位小数；非零小值低于 0.01 M 时显示 `<0.01 M`。已有 v2 缓存直接重新汇总，无需迁移或重扫历史。
- 日期方格为本地时区的公历 18 周（周一至周日），按首个关联生成步骤的 `created_at` 归档；响应和执行标识须同时匹配。刷新时间、文件修改时间及会话创建时间不用于历史归档。
- 日期缺失或冲突时保留用量总数，但不塞进某一天；空心虚线为未知，有色虚线为已读部分。只有本机保留数据完整、且无日期缺失时，无记录日才显示 0；不代表该日账户全设备用量为零。悬停或点击查看当日 M 单位数值，不触发数据读取。
- Antigravity 使用居中的 Gemini / Claude-GPT 原生分段标签，一次仅展示一组额度；记住面板选择，与菜单栏显示组独立。切换标签不读取数据，Token 日期格仍统计全部模型。
- 面板采用紧凑单屏布局，不增加纵向滚动容器或滚动条。Token 底部常驻说明已移至“全部模型”、状态、刷新入口与图例的悬停提示；部分 / 未更新状态保留简短标识。Codex 页面布局及统计口径不变。
- 内部元数据非公开协议；当前针对 Antigravity 2.12.2 的 schema v1 验证。未知格式显示部分/不可用，不猜测为零。

隔离交互状态检查及可选的本机只读探针（后者最多两批，临时缓存自动清理，不输出用量值或标识）：

```bash
swiftc -O -parse-as-library Core/*.swift App/Stores/AntigravityTokenStore.swift Tools/AntigravityTokenProbe.swift -o build/ag-token-probe
build/ag-token-probe
build/ag-token-probe --local
```

## Stay Awake

弹窗中的“保持唤醒”使用 macOS 原生 `ProcessInfo` 活动断言，不依赖外部
Caffeine 或 `caffeinate` 进程。默认模式只阻止 Mac 因用户空闲进入系统睡眠，显示器
仍可按 macOS 的锁屏与显示器睡眠设置熄灭；也可以选择同时保持显示器唤醒。选择有限
时长时会在到期后自动释放，无限期状态会在 App 重启后恢复。显示器模式会被记住，
在运行中的定时任务里切换模式不会重置到期时间。

该功能不会阻止用户手动选择睡眠、合上 MacBook 屏幕、低电量或系统因其他安全原因
进入睡眠。退出 QuotAI 时，当前进程持有的活动断言会立即释放。

## 语言

App、菜单栏、设置和错误提示均支持 English 与简体中文。默认跟随 macOS 语言，也可以在“系统设置 → 通用 → 语言与地区 → 应用程序”中单独指定 QuotAI 的语言；切换后重新启动 App 生效。

## App Icon

图标主稿保存在 `Design/AppIcon-master.png`，生产尺寸集位于 `Assets.xcassets/AppIcon.appiconset`。Xcode 会在构建时生成并写入 `AppIcon.icns`；菜单栏仍保留额度文字，方便直接读取剩余百分比。
