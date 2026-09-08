# 2.0.8 (25) Antigravity 居中双标签 · 2026-09-08

隔离验收检查点：界面调整、56 项 Swift 测试、Universal 候选构建与隔离原生预览验收通过。以下记录形成于打包、安装与发布之前，不代表后续安装或 GitHub Release 状态。

## 当前约定

- 固定两个原生分段标签：Gemini、Claude / GPT。标签按自身宽度水平居中，一次只显示选中额度池的 5h / 7d 行，不新增切换动画。
- 面板选择保存在独立的 `quotaPanelAntigravityGroup`，不更改菜单栏显示组。选中组缺失时按 Gemini、3p 顺序回退到可用组；未知池不冒充已知模型，也不追加第三个标签。
- 本机 Token 与日期格仍为全部模型，不随额度标签筛选。切换只更新视图和偏好，不启动读取、轮询或监听。
- 删除 build 24 的 `BoundedAntigravityContent`、高度测量及 AppKit 高度传递。当前面板无纵向 ScrollView 或滚动条。
- Token 卡片底部不再有状态、日期口径和本机范围的常驻说明段落。说明移至全部模型、刷新、状态及图例的悬停提示；部分 / 未更新标识仍在标题行，日期虚线与未知图例保留。无数据时仍显示必要空态。
- Core 元数据预算、缓存、来源及日期口径未改，之前的只读协议证据保留在 build 24 日期记录中。

## 已执行验证

- `swift test`：56 项通过，新增三个标签测试覆盖两项标签、正确额度、空 / 过期选择、单组、未知组、返回顺序及独立偏好键。日志：`build/ag-quota-tabs-tests.log`。
- Universal Release：2.0.8 (25)，`x86_64 arm64`，`CODE_SIGNING_ALLOWED=NO`，构建成功；无新增 Swift 警告。已有 Simulator 环境提示和无 AppIntents 的跳过提示不影响此 macOS 构建。日志：`build/ag-quota-tabs-release.log`。
- 独立原生 `.app` 预览使用生产视图 / Token store 与合成数据源，不读取真实 Token 或调用厂商。CUA 实点 Gemini / Claude 双向切换，分别读回 76% / 61% 与 44% / 28%；总量保持 1.6 M、调用次数保持 120，证明该交互未触发额外合成源读取。
- 手动继续读取后，合成调用次数 120 → 220、总量 1.6 M → 2.5 M，标题的 Partial 状态移除，底部仍无说明段落或滚动条。该计数只是测试数据，不是账户用量。
- CUA 实际截图检查英文浅色、中文深色：两项标签水平居中、所有日期格、保活和底部刷新 / 设置入口完整可见；AX 树无 scroll area / scroll bar。重启独立预览后保留 Claude 标签选择，再切 Gemini 正确。
- 英文四模型大数值 / 部分数据离线卡片图已目视检查，无文本溢出：`build/qa/ag-tabs-token-card-en-partial.png`。日期范围和未知 / 零值图例均可见。
- `git diff --check`、双语 strings 的 `plutil -lint` 通过。

## 产物与边界

- 候选：`build/AGTokenCandidate/Build/Products/Release/QuotAI.app`；这是未签名构建，不是正式分发安装包。
- 本机 `/Applications/QuotAI.app` 本轮读回为 2.0.7 (22)，原安装进程保留运行。预览有独立偏好域，本轮未替换安装 App 或修改真实统计缓存。
- 原生分段 Picker 不受 SwiftUI ImageRenderer 支持，完整面板离线 PNG 在该位置出现占位符，因此不能作为标签验收证据；标签外观采用实际原生 CUA 截图。Token 独立卡片不含该原生控件，可用作静态补充证据。
- 本轮未验收正式菜单栏锚点的多屏 / 极小屏幕边缘、纯指针悬停、长期能耗或运行中厂商实例；不把隔离预览等同于生产安装验收。
