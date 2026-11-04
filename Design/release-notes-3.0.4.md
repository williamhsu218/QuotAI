# QuotAI 3.0.4（66）

- 修复应用内自动更新后小组件加载失败：升级恢复不再调用 Launch Services 或 PlugInKit 注册命令，保留系统注册及已有 AppIntent 额度选择。
- 自动总览与可选额度分别使用独立的静态和 AppIntent Timeline Provider，避免静态实例进入缺少 Intent 的分支。
- 安全识别仍存活但旧文件已被更新器删除的扩展：核对内核验证的签名类别、有效状态、团队、扩展标识和用户；不凭进程名称终止其他程序。
- WidgetKit 配置查询增加超时；使用本次恢复请求与当前 build 的独立响应确认已配置的组件类型，未确认时保留重试机会。响应文件只含随机请求标识、build 与组件类型，不记录额度或账户信息。
- 增加安装前扩展交接和单实例保护，避免自动重启时多个主进程并发修改小组件恢复状态。
- 保留现有组件标识、环形样式、彩色图标、固定额度选择及共享开关。发布构建不再注入调试附加权限。

验证：169 项 Swift 测试、严格格式检查、Debug 构建、界面渲染、隔离探针和 Universal 打包通过[完整 CI](https://github.com/williamhsu218/QuotAI/actions/runs/41767850409)。macOS 27.2 上，原始 3.0.3（60）经真实 Sparkle 下载、安装、自动重启升级至 3.0.4（66），系统成功接收两类组件的新时间线，未出现 1101/1103 错误；用户确认两类组件正常显示、固定选择保留，点击可打开应用。公开下载包的 SHA-256、Ed25519 签名、嵌套签名、通用架构及文件与安装应用一致。已发布为 [GitHub Releases 最新版](https://github.com/williamhsu218/QuotAI/releases/tag/v3.0.4)。本机证据位于 `build/qa/widget-ota-upgrade/` 和 `build/qa/release-3.0.4/`。
