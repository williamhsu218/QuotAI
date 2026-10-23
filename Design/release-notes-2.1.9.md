# QuotAI 2.1.9

支持 Antigravity 的 Gemini 4 Argon 独立周额度与账号权限。

- 面板新增 Argon 标签，菜单栏额度组可选择 Argon；只显示接口实际返回的额度窗口与重置时间，不补出 5 小时额度，也不与其他模型池相加。
- 通过账号模型配置的启用状态与适用套餐判断 Argon 权限；读取失败保留选择并隐藏数字，明确无权限才回退，额度耗尽仍显示 0% 和重置时间。
- 付费 Pro 的 Argon 使用独立周额度；Ultra 并入 Gemini 额度池。仅在接口返回独立池时显示 Argon 标签，避免虚构重复额度。
- 保留面板与菜单栏的独立选择，以及现有的来源切换动画。模型公开可用范围参考 [Antigravity 官方说明](https://antigravity.google/docs/models)，实际权限以账号响应为准。

提供 macOS 14+ 的 Apple Silicon / Intel Universal 包，采用 ad-hoc 签名，未进行 Developer ID 签名或公证。

## 验证

- 127 项 Core 测试和隔离状态探针已通过；覆盖独立周额度、权限未知、无权限回退、耗尽、共享池和恢复。
- 已通过 Antigravity 2.25.0 真实账号只读链路，以及中英文原生窗口、模型组切换、菜单栏设置和异常状态检查。
- 2.1.9（48）Universal Release 构建和严格 ad-hoc 签名检查通过；主程序与辅助程序均包含 Apple Silicon / Intel 架构。
- 正式安装版完成 Argon 周额度刷新、菜单栏额度组选择及关于页面版本检查；安装文件与签名候选包的全部 9 个文件 SHA256 一致。验收后的完整用户偏好已恢复，Claude 配置与历史数据保留。
