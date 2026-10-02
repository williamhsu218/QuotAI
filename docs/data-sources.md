# 数据来源与隐私

[返回项目首页](../README.md)

Codex、Antigravity 与 Claude Code 分别读取和呈现；一个来源不可用时，不借用另一个来源的数据。
订阅剩余额度与 Codex Token 用量的含义不同，不能相加或解释成同一个账单。

## Codex 与 Antigravity 额度

App 通过本机 `codex app-server --stdio` 的 `account/rateLimits/read` 读取 Codex
额度与套餐名称，不上传数据，也不保存登录令牌、账号 ID 或邮箱。最近一次成功的
Codex 额度、套餐名称与 Token 用量仅缓存在本机 Application Support 目录。
可选的 `account/usage/read` 失败或超时不影响额度读取；暂时缺失时保留最近缓存，
接口明确返回空用量时清除旧图表。Token 数据为账户接口统计，不代表本 App 产生的用量。

Antigravity 使用另一条完全独立的本机链路：运行时发现其动态 language-server
监听端口，并调用
`exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`。瞬时本地
CSRF 信息只在单次刷新内驻留内存；Antigravity 额度、认证信息和账户明细不会写入
缓存或日志。该 RPC 曾在 Antigravity 2.8.1 验证，但不是公开承诺稳定的接口；
Antigravity 未运行或协议变化时，App 显示“不可用”，不会显示成 0，也不会回退为
Codex 额度。

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
- **Antigravity**：只显示实时额度，按 Gemini 和 Claude / GPT 分组；面板选择与菜单栏选择独立。
  不再读取本机会话数据库，也不显示 Token 总量、模型汇总或日期图表。
- **Claude Code**：点击刷新执行官方本机 `claude -p /usage --output-format json`，查询 Pro/Max 的 5h、7d，换算为剩余百分比与北京时间重置时间。无需等待会话回调或固定会话。
  查询时间是本机完成时间，官方输出未提供源采样时间和账号标识，不表示持续实时监控。
  缓存载入、超过 30 分钟或失败时，旧结果灰显为“上次查询”；到各窗口重置时间后隐藏数字。
  缺少窗口、没有有效重置时间或重置已过时，该窗口不显示数字，其余有效窗口独立显示。
  两个窗口都没有有效重置时间时，记录本次空结果并清除旧数字，不作为格式错误。
  不补旧值，不推算为 100%。不显示重置卡、查看入口、套餐或 Token 统计。

## Claude Code 查询与隐私

本机 CLI 2.1.285、2.1.287 已实测 `/usage` 在 `-p` 模式下返回 `num_turns=0`、`total_cost_usd=0`、空 `modelUsage`。
这是官方 CLI 内置命令，额度位于 JSON 的文字 `result`；不是独立的第三方订阅额度 HTTP API。
格式变化、非零轮次/费用/Token、登录或网络失败时明确提示，不从模型回复估算额度。
依据：[官方命令](https://code.claude.com/docs/en/commands)、[非交互模式](https://code.claude.com/docs/en/headless)。

查询在空临时目录运行，禁用 hooks、MCP 和工具，不持久化会话。仅手动刷新调用一次，
最多 20 秒，支持取消与并发保护；启动只载入专用缓存，后台其他来源刷新不查询 Claude。
Claude CLI 自行使用现有登录，QuotAI 不读取凭据、钥匙串、会话正文、桌面缓存或私有模块，
不调用未公开 OAuth 接口。原始输出只在内存中解析，大小受限；stderr 不保存。

本机 Application Support 的 `claude-usage-query-v1.json` 只保存白名单额度窗口和查询完成时间，
使用 0600 权限与原子替换；成功查询也可记录没有有效窗口的空结果。失败保留旧结果，清除或停用时取消查询并拒绝迟到结果。
点击“清除查询缓存”仅删除此文件，不清除 Claude 会话、登录或旧恢复记录。

## 旧版本升级与数据保留

2.0.14 安装过 Claude Code 状态栏桥接的用户，升级时会进行一次兼容恢复：

- 仅在当前 `statusLine` 命令精确匹配 QuotAI 生成的桥接命令、且有可用恢复记录时，
  备份当前配置并恢复之前的 `statusLine`；之前没有该项时移除桥接项。
- 支持默认 `~/.claude/settings.json` 和 `CLAUDE_CONFIG_DIR`。用户已自行修改的状态栏命令不会被替换；
  配置或恢复记录不可读、恢复期间配置变化时保留原状。
- 已打开终端若仍调用 `QuotAI --claude-statusline`，仅转交给之前的状态栏命令以保持输出，
  不再保存额度报告。迁移记录和配置备份保留。
- 旧 Antigravity Token 缓存和 Claude 额度缓存不再读取，也不自动删除；它们不是当前数据源。
  不读取或删除会话正文、凭据、钥匙串或账户数据。

2.1.1 同样停止 v2 状态栏采集，仅在配置仍由 QuotAI 持有时恢复原配置。冲突则保留用户配置并提示；旧报告与备份不删除，也不用于当前展示。新查询不会安装或改写状态栏命令。
当前版本的验证状态见[2.1.3 版本说明](../Design/release-notes-2.1.3.md)。
