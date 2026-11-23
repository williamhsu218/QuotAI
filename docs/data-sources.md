# 数据来源与隐私

[返回项目首页](../README.md)

Codex、Antigravity 与 Claude Code 分别读取和呈现；一个来源不可用时，不借用另一个来源的数据。
订阅剩余额度和 Token 活跃度各自展示。Codex 用量来自账户接口，Claude Code 和 Antigravity 用量来自本机日志。

## Codex 与 Antigravity 额度

App 通过本机 `codex app-server --stdio` 的 `account/rateLimits/read` 读取 Codex
额度与套餐名称，不上传数据，也不保存登录令牌、账号 ID 或邮箱。最近一次成功的
Codex 额度、套餐名称与 Token 用量仅缓存在本机 Application Support 目录。
可选的 `account/usage/read` 失败或超时不影响额度读取；暂时缺失时保留最近缓存，
接口明确返回空用量时清除旧图表。Token 数据为账户接口统计，不代表本 App 产生的用量。

较早的 Antigravity 版本通过本机 language-server 读取额度。QuotAI 发现它的监听端口，并调用
`exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`。瞬时本地
CSRF 信息只在单次刷新内驻留内存；Antigravity 额度、认证信息和账户明细不会写入
缓存或日志。该 RPC 曾在 Antigravity 2.8.1 验证，但不是公开承诺稳定的接口；
Antigravity 2.34.0 改用新的本地连接方式。此时 QuotAI 调用已登录的 Antigravity CLI
1.5.13 或更新版本，通过内置命令 `agy -p /usage --output-format json` 读取额度与重置时间，
通过 `agy models` 读取该账号的可用模型。面板底部会显示 `CLI`。若要查看桌面端账号的额度，
请在两端登录同一个账号。CLI 的 `/usage` 结果未包含套餐名时，QuotAI 通过
`--settings` 配置本次查询的 `statusLine` 回调，异步读取 `plan_tier`。回调只交付套餐字段，查询结束后清理临时文件，
套餐缓存仅保留在内存中。已知套餐在短暂查询失败期间继续显示，后续成功查询会更新徽标。
QuotAI 在临时目录运行查询，使用 CLI 自己的登录状态，只接受零轮次、零 Token 的结构化额度报告。
[Antigravity CLI 官方用法](https://antigravity.google/docs/cli/headless/) / [Status line 文档](https://antigravity.google/docs/cli/statusline)

旧本机接口会同时读取 `GetUserStatus` 的账号模型配置，以启用状态和适用套餐判断第三方与 Argon 模型权限，
不按模型版本或套餐名称推测，也不把额度池存在或剩余百分比当作使用权限。
确认没有可用第三方模型时隐藏该标签；仅剩 Gemini 时取消切换控件，面板与菜单栏的
第三方选择回退为 Gemini。额度为零仍保留标签、0% 与重置时间。
模型权限读取失败时保留选择、隐藏第三方百分比并提示重试；整个额度请求失败时清除旧快照，
菜单栏显示 `--`。只有明确无权限时才持久化上述回退，临时读取失败不会改写选择。
设置页只列可展示的额度组，并说明无第三方模型或权限读取失败的原因。

2026-10-23 在 Antigravity 2.25.0 核实：付费 Pro 可用 Gemini 4 Argon，独立额度桶为
`gemini-argon-wtu-weekly`，只含 `weekly` 周期；面板和菜单栏按该池的比例、重置时间显示，
不补出 5 小时额度，也不与 Gemini 或 Claude/GPT 相加。Argon 权限未知时保留选择、隐藏数字，
明确无权限才回退；耗尽时保留 0% 和重置时间。
官方接口说明 Ultra 的 Argon 并入较大的 Gemini 额度池，因此仅在实际返回独立池时显示 Argon 标签，
不根据模型存在或套餐名虚构独立额度。模型权限以实际账号响应为准，公开可用范围参考
[官方模型说明](https://antigravity.google/docs/models)。

从 Finder 启动时，App 会保留已有的 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、
`CODEX_CA_CERTIFICATE` 和 `SSL_CERT_FILE`，并在未设置代理环境变量时读取 macOS
系统的 HTTP、HTTPS 或 SOCKS 代理，再传给 `codex app-server`。代理地址和证书路径
不会写入日志。

App 会优先尝试 ChatGPT／Codex 桌面版内置的 Codex 命令，兼容新的
`Contents/Resources/codex-cli/bin/codex` 和旧的 `Contents/Resources/codex` 路径，
再尝试本机 Codex CLI 与 PATH 中的 Codex，并选择首个能够返回额度的版本。
桌面版命令不依赖终端的 Node 环境；设置中手动指定的路径仍为唯一候选。
额度仅适用于 ChatGPT Codex 登录；API Key 登录不包含 ChatGPT
订阅额度。若本机所有 Codex 版本都不支持 `account/rateLimits/read`，App 会提示更新
ChatGPT 或 Codex CLI。

本项目面向个人本机使用，构建脚本采用无开发者账号签名的本地构建方式，不需要 Apple Developer Program。

## 当前显示范围

- **Codex**：订阅额度、套餐、重置卡与账户 Token 图表。Token 图表来自账户接口，不扫描本地对话。
- **Antigravity**：实时额度按 Gemini、Argon（接口返回独立池时）和 Claude / GPT 分组，面板选择与菜单栏选择独立。
  面板另显示 Antigravity IDE 和 CLI 本机会话合计的 Token 活跃度。
- **Claude Code**：点击刷新执行官方本机 `claude -p /usage --output-format json`，查询 Pro/Max 的 5h、7d，换算为剩余百分比与按系统时区显示的重置时间。无需等待会话回调或固定会话。
  查询时间是本机完成时间，官方输出未提供源采样时间和账号标识，不表示持续实时监控。
  缓存载入、超过 30 分钟或失败时，旧结果灰显为“上次查询”；到各窗口重置时间后隐藏数字。
  缺少窗口、没有有效重置时间或重置已过时，该窗口不显示数字，其余有效窗口独立显示。
  两个窗口都没有有效重置时间时，记录本次空结果并清除旧数字，不作为格式错误。
  不补旧值，不推算为 100%。套餐通过官方 `claude auth status --json` 读取并独立缓存。
  面板另显示 Claude Code 本机会话的 Token 活跃度。

## 本机会话 Token 活跃度

- Claude Code 读取 `~/.claude/projects` 的 JSONL；如果 App 进程配置了 `CLAUDE_CONFIG_DIR`，则使用其 `projects` 目录。
  统计消息的输入、输出、缓存读取和缓存创建 Token，并按消息 ID 去除重复的流式用量记录。
- Antigravity 读取 `~/.gemini/antigravity`、`~/.gemini/antigravity-cli` 和 `~/.antigravity-ide` 下的日志及会话 JSON／JSONL。
  优先使用记录自带的总数。需要合计时，按日志格式区分已包含在输入中的缓存和单独记录的缓存。

应用启动时和之后每 5 分钟在后台扫描已启用的来源。打开面板或切换来源时立即刷新，面板打开期间每分钟检查更新。
图表按本机时区显示最近 18 周，归档记录沿用采集时的日期。累计值和连续天数包含本机当前日志与已归档的历史用量。
原始记录只在内存中解析。本机 Application Support 的 `QuotAI/Insights/token-activity-v1.json` 以 0600 权限原子写入，
只保存文件路径与 Claude 消息 ID 的 SHA-256 摘要、文件大小和修改时间、按日 Token 计数与归档状态。
正常扫描中确认会话文件已删除时，已记录的用量会保留在归档中。文件恢复或同一 Claude 消息出现在多个日志时，避免重复计数。
“设置 → 功能 → 本机 Token 历史台账”可清空归档，仍在磁盘上的会话会按当前日志重新统计。首次扫描之前已删除的会话无法恢复。

## Claude Code 查询与隐私

本机 CLI 2.1.285、2.1.287 已实测 `/usage` 在 `-p` 模式下返回 `num_turns=0`、`total_cost_usd=0`、空 `modelUsage`。
这是官方 CLI 内置命令，额度位于 JSON 的文字 `result`；不是独立的第三方订阅额度 HTTP API。
格式变化、非零轮次/费用/Token、登录或网络失败时明确提示，不从模型回复估算额度。
依据：[官方命令](https://code.claude.com/docs/en/commands)、[非交互模式](https://code.claude.com/docs/en/headless)。

查询在空临时目录运行，禁用 hooks、MCP 和工具，不持久化会话。默认每次手动刷新调用一次；用户可在功能页开启 15/30/60 分钟查询，
最多 20 秒，支持取消与并发保护；启动只载入额度缓存，后台其他来源刷新不查询 Claude 额度。
首次启用与后续启动读取一次 `claude auth status --json`，手动或用户启用的定时刷新时同步更新套餐，最长等待 5 秒。
此命令不生成模型回复；仅接受已登录的官方 claude.ai 订阅，显示其报告的 Pro、Max、Team 或 Enterprise。
Max 不附加未经报告的 5x/20x 档位。退出登录、API 登录或未知套餐会清除旧名称；
命令暂时失败时保留缓存，套餐徽标提示其为缓存。Claude 的套餐映射与 OpenAI 独立。
额度查询由 Claude CLI 自行使用现有登录，
不调用未公开 OAuth 接口。原始输出只在内存中解析，大小受限；stderr 不保存。

本机 Application Support 的 `claude-usage-query-v1.json` 只保存白名单额度窗口和查询完成时间，
使用 0600 权限与原子替换；成功查询也可记录没有有效窗口的空结果。失败保留旧结果，清除或停用时取消查询并拒绝迟到结果。
套餐另存于 `claude-subscription-v1.json`，只含格式版本与白名单套餐标识，使用 0600 权限与原子替换；
不保存 auth status 的原始输出、邮箱或账号标识。点击“清除查询缓存”删除额度与套餐这两个缓存，
并取消未完成查询，不清除 Claude 会话、登录或旧恢复记录。

## 旧版本升级与数据保留

2.0.14 安装过 Claude Code 状态栏桥接的用户，升级时会进行一次兼容恢复：

- 仅在当前 `statusLine` 命令精确匹配 QuotAI 生成的桥接命令、且有可用恢复记录时，
  备份当前配置并恢复之前的 `statusLine`；之前没有该项时移除桥接项。
- 支持默认 `~/.claude/settings.json` 和 `CLAUDE_CONFIG_DIR`。用户已自行修改的状态栏命令不会被替换；
  配置或恢复记录不可读、恢复期间配置变化时保留原状。
- 已打开终端若仍调用 `QuotAI --claude-statusline`，仅转交给之前的状态栏命令以保持输出，
  不再保存额度报告。迁移记录和配置备份保留。
- 旧 Antigravity Token 缓存和 Claude 额度缓存不再读取，也不自动删除；它们不是当前数据源。

2.1.1 同样停止 v2 状态栏采集，仅在配置仍由 QuotAI 持有时恢复原配置。冲突则保留用户配置并提示；旧报告与备份不删除，也不用于当前展示。新查询不会安装或改写状态栏命令。
当前版本的验证状态见[3.0.3 版本说明](../Design/release-notes-3.0.3.md)。

Antigravity 本机请求使用临时 URLSession，绕过代理且不持久化 Cookie 或凭据；只连接探测到的
`127.0.0.1` / `[::1]` 监听端口，拒绝重定向，响应上限为 1 MiB。自签名 TLS 兼容仅限这两个
回环地址，外部服务的证书校验保持系统默认。成功端点及运行时令牌仅驻留内存；进程退出或请求失败时重新探测。
自动刷新间隔变更会重新计时，在途请求继续按原有超时和数据完整性规则完成。


## 可选功能的本机数据

- 提醒只处理本次成功查询的非历史结果；启动、开启提醒或更改阈值时重新建立基线。低额度跨越阈值时通知一次，恢复后才重新布防；重置提醒必须由新响应确认下一重置窗口。
- 历史记录仅保存来源/额度组/窗口、查询时间、剩余百分比及重置时间，不保存账号标识或原始响应。JSON 原子写入、权限 0600；最多 30 天或 12,000 条，关闭记录保留已有数据，清空需二次确认。
- 小组件只读取 App Group 的最小快照，包含已启用来源各额度组的窗口、剩余百分比和时间，供每个组件独立选择；配置由 WidgetKit 保存。扩展不运行 CLI 或访问额度网络接口。到重置时间隐藏旧百分比；超过 30 分钟或缓存结果灰显。不开启共享时不创建快照，关闭后清空已有快照；已选额度缺失时提示不可用，不自动替换成其他额度。
- 更新仅访问配置的 HTTPS GitHub 源；Ed25519 公钥在应用内，项目私钥仅在发布机器钥匙串。额度、历史和账号信息不加入更新请求。
