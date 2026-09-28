# 数据来源与隐私

[返回项目首页](../README.md)

Codex 与 Antigravity 分别读取和呈现；一个来源不可用时，不借用另一个来源的数据。
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

App 会依次尝试本机 Codex CLI、PATH 中的 Codex 和 ChatGPT 内置 Codex，并选择首个
能够返回额度的版本。额度仅适用于 ChatGPT Codex 登录；API Key 登录不包含 ChatGPT
订阅额度。若本机所有 Codex 版本都不支持 `account/rateLimits/read`，App 会提示更新
ChatGPT 或 Codex CLI。

本项目面向个人本机使用，构建脚本采用无开发者账号签名的本地构建方式，不需要 Apple Developer Program。

## 当前显示范围

- **Codex**：订阅额度、套餐、重置卡与账户 Token 图表。Token 图表来自账户接口，不扫描本地对话。
- **Antigravity**：只显示实时额度，按 Gemini 和 Claude / GPT 分组；面板选择与菜单栏选择独立。
  不再读取本机会话数据库，也不显示 Token 总量、模型汇总或日期图表。
- **Claude**：不再提供独立页面、菜单栏数据源或设置入口，不显示桌面／终端的 5 小时与每周快照额度，
  不轮询桌面额度缓存，也不采集终端状态栏中的额度数据。

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

恢复兼容不等于重新启用 Claude 数据源。当前候选的验证状态见[2.0.15 版本说明](../Design/release-notes-2.0.15.md)。
