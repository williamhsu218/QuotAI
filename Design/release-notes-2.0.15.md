# QuotAI 2.0.15

## 更新内容

- Antigravity 页面仅保留实时额度，移除本机会话 Token 总量、模型汇总、日期图表与历史读取入口。
- 移除 Claude 独立页面、菜单栏数据源、设置入口及 5 小时／7 天快照额度；停止桌面缓存轮询和终端额度采集。
- 保留 Codex 的订阅额度、重置卡和账户 Token 图表；Antigravity 的 Gemini、Claude / GPT 实时额度分组保持独立。
- 升级时识别 QuotAI 安装的旧 Claude Code 状态栏命令，备份后恢复之前的配置；用户自行修改的命令保持不变。
  已打开终端仍调用旧桥接时，仅兼容原状态栏输出，不再采集额度。缺少恢复记录时保留配置，避免覆盖用户设置。
- 旧的 Antigravity Token 与 Claude 额度缓存保留，但不再读取；不删除会话、凭据或历史数据。
- 同步精简界面、设置、测试工具和项目文档。

## 验证与本机安装

2026-09-28 已将 2.0.15（35）恢复到本机 `/Applications/QuotAI.app`，并核对运行进程、完整应用文件与签名。
发布 ZIP 直接打包这份已运行的应用；解压后的应用内文件与本机安装版逐字节一致，随附 SHA-256 校验文件。

- 70 项测试通过；独立 Universal Release 构建成功，发布 ZIP 内含 Apple Silicon 与 Intel 架构。
- 原生弹窗使用隔离数据检查了中英文、深浅色、额度分组切换与设置入口；旧 Claude 来源选择会回到 Codex，Codex Token 图表继续显示。
- 两种输入大小的旧状态栏桥接运行检查通过：保留原命令输出，不再写入额度缓存。
- 本机升级已恢复 QuotAI 接入前的 Claude 状态栏配置，并生成原文件备份；其他 Claude 设置、文件权限、QuotAI 偏好及旧 Antigravity Token 数据保持不变。
- 保留上一版本应用以便回退。打包与验证方式见[开发与验证](../docs/development.md)。

运行要求为 macOS 14+；沿用个人本机使用的 ad-hoc 签名，不含 Apple Developer ID 或 Apple 公证。
