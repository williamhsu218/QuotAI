# QuotAI 3.0.6（69）

- Claude Code 与 Antigravity 面板新增 Token 活跃度，显示累计用量、连续活跃天数和最近 18 周的每日用量。悬停方格可查看精确数值。
- Claude Code 从本机会话日志读取实际用量，按消息 ID 合并重复的流式更新。Antigravity 汇总本机 IDE 和 CLI 的日志，统计覆盖本机记录的所有模型。
- 活跃度沿用 Codex 的展示和配色。打开或切换面板后在后台读取日志，统计结果缓存在内存中。
- 三个来源的额度查询、重置时间和 Quota History 维持原有流程。Token 活跃度与剩余额度各自显示。

验证：171 项核心测试通过。本机安装的 3.0.6（69）已完成 Claude Code、Antigravity 的 Token 统计及额度刷新验收。Universal 安装包沿用 Apple Development 团队签名和 App Group，尚未完成 Developer ID 公证。
