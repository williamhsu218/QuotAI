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
- **Claude Code**：通过官方文档化的状态栏 JSON 接收 `rate_limits.five_hour` / `seven_day`
  的已用百分比与 Unix 秒重置时间，换算为剩余百分比。只表示所选会话的最近报告，
  不宣称后台实时查询或已绑定当前账户。官方未提供源采样时间；本机收到时间也不代表服务端刷新时间。
  两个窗口分别计算 30 分钟展示期限；相同窗口值的重复回调不能延长期限。陈旧或到重置时隐藏数字，
  缺少窗口不补旧值、不推算为 100%。多个会话分别隔离，载入后默认选择最近仍可显示的完整报告；手动固定后不自动切换。
  不显示重置卡、任何查看入口、套餐或 Token 统计。

本机 Claude CLI 2.1.285 实测：交互模式产生官方状态栏报告；`-p` 模式有 session 和官方流式额度事件，但不执行状态栏回调。
流式事件需由启动 CLI 的宿主转发，QuotAI 不旁路读取其他进程输出或会话文件。
依据：[官方 SDK 额度事件](https://code.claude.com/docs/en/agent-sdk/python#ratelimitinfo)。

## Claude Code 接入与隐私

在设置中接入后，QuotAI 先保留恢复记录与原字节备份，再修改 Claude 用户设置的
`statusLine.command`，保留其他设置及原状态栏参数。独立辅助程序将同一份 stdin
转交原命令以保留输出；停用时仅恢复仍属于 QuotAI 的配置，用户自行改写的配置不会被覆盖。
默认使用 `~/.claude/settings.json`，也支持 `CLAUDE_CONFIG_DIR`。损坏配置、符号链接或冲突时停止覆盖。

报告保存在本机 Application Support 的独立 v2 文件，只存必要的额度窗口、加盐会话指纹与本机时间。
输入、文件大小和会话数量有上限，并发写入有锁，文件采用私有权限与原子替换。
不保存原始状态栏 JSON、工作目录、会话正文、transcript 路径、cost 或 context Token。
不读取凭据、钥匙串、桌面缓存、历史对话，不调用未公开 OAuth 接口，也不为刷新生成模型请求。
CLI 正常使用自动生成 JSON，App 在启动、接入或手动刷新时载入，不监听文件自动变化。
刷新只重读本机报告；配置连接与是否收到有效报告分别呈现。

官方依据：[状态栏额度](https://code.claude.com/docs/en/statusline#rate-limit-usage)。

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

旧桥接恢复兼容与新 v2 接入分别处理。新版本不会因旧的启用偏好自动写入状态栏配置。
当前版本的验证状态见[2.1.0 版本说明](../Design/release-notes-2.1.0.md)。
