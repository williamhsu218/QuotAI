# 2.0.8 (24) Antigravity 日期方格 · 2026-09-08

历史记录：本文的限高滚动布局已按用户后续要求在 build 25 中移除，改为居中双标签与无滚动条的紧凑单屏布局。当前界面验收见 [build 25 记录](antigravity-quota-tabs-qa-2.0.8.md)；下文仅保留 build 24 当时的证据，不代表当前布局。

状态：实现完成，53 项 Swift 测试、Universal 候选构建、本机限量只读探针与独立原生预览交互通过。未覆盖本机安装版，未提交或发布 GitHub。

## 图表约定

- 目的：在 QuotAI 原生菜单栏面板中查看本机保留 Antigravity 会话的每日输入＋输出强度，不推断账户账单或完整使用习惯。
- 形式：公历近 18 周、周一至周日的 18 × 7 方格；生产容器宽 340 pt，格边 11 pt，间距 2.8 pt，与已有 Codex 风格一致。Codex 的组件与口径不改。
- 数据：响应去重后的输入＋输出；缓存读取单列。可靠时间缺失或冲突时保留总数但不分配到日期，明确未定日期次数。
- 颜色：沿用 AppTheme.systemTeal 单色深浅，以可见日期的峰值分 4 档；不能跨供应商直接比较颜色强度。零值为中性实心，未知为空心虚线；部分值加虚线和文本。未来日不显示数据。
- 交互：悬停或点击显示日期与精确值；只读内存，不触发刷新。部分历史没有被当作零值，也不显示活动连胜之类的派生指标。
- 高度：Antigravity 内容超限后滚动。AppKit 仅传递状态栏所在显示器的可用高度，SwiftUI 管理滚动；顶部供应商、保活和底部入口固定。

## 时间与字段证据

1. 使用 `Tools/InspectAntigravitySchema.mjs` 从本机 Antigravity 2.12.2 的 language_server 二进制中读取限定范围内的 protobuf 描述符。它是只读诊断工具，不包含在正式 App 中。
2. ModelUsageStats #1 是 `model` 枚举，#2 才是 `input_tokens`；已移除 build 23 中多加的模型编号。#3 是总输出，#9 / #10 分别是 thinking / response output，校验和一致且不重复相加。
3. ChatStartMetadata #4 是声明的 `created_at`，但样本缺失；#10 明确定义为 `context_window_metadata`，不能按开源 CLI 对另一版本的猜测当作时间解码。
4. `CortexStepGeneratorMetadata.step_indices` 给出生成步骤索引。`steps.metadata` 的 #1 是标准 Timestamp 创建时间，#9 的响应标识和 #12 的执行标识可用于验证关联。
5. `Tools/AntigravityTimestampProbe.swift` 限量抽查 4 个会话、71 条生成记录及 158 条关联步骤元数据，合计 190874 字节。71 条记录的首个关联步骤响应标识全部匹配，158 个执行标识全部匹配；样本中无时间倒序。未读取步骤正文或打印原始标识、Token 数值。
6. 正式读取只按主键读取第一个关联步骤，要求响应和执行标识同时匹配，校验秒、纳秒与合理时间范围。未知 schema / 日期 / 关联不猜测；不转用文件 mtime、刷新日期或会话创建日期。

这证明本机已检查协议和样本的日期可用，不是官方计费口径保证，也不保证其他 Antigravity 版本保持兼容。

## 轻量与缓存边界

- 仍无新增定时器、轮询、文件监听、网络、模型请求、CLI 或常驻连接。
- 单批最多 4 个源库 / 512 条元数据 / 768 KiB；生成和步骤共享行数、字节及 80 ms 源读取工作预算。缓存写入及汇总不属于整次请求的硬时限。
- 步骤元数据单条最多 4 KiB；只查询 `steps.metadata`，从不读取 `step_payload`。不足一个完整生成＋日期查询的剩余预算时，保留游标供下次继续，不永久漏掉日期。
- 日汇总由 SQLite 对 UTC 毫秒时间按本地时区归档；时区变化可从缓存重新汇总，不必重读源。原始响应 / 执行标识不落盘。
- 新缓存是 `metadata-v2.sqlite` / user_version 2。旧 v1 计数不复用、不删除；正式版按需建立新缓存。来源 schema 仍是 user_version 1，不能与缓存版本混淆。

## 已执行验证

- `swift test`：53 项通过，含原 46 项及 7 项日期测试。覆盖输入字段更正、响应与执行双匹配、坏时间 / 纳秒 / 未来值、跨本地午夜、去重日期冲突、缺索引降级、同预算续读不丢日期、旧缓存拒绝、公历 / DST / 未知与零值。
- 百万字节 `step_payload` 合成夹具的实际读取统计小于 1 KiB，步骤正文未查询；源表修改 / 步骤删除能使日期归档重新校验。
- 新版只读探针使用可清理的临时缓存，读取真实源库两批：82 ms / 59 ms；各 512 条元数据（各含 256 条步骤）；376822 / 375378 字节。两批均无不可用库、排除记录或未定日期，累计覆盖 3 个有数据的日期；34 个源库仍未全读完，没有继续全量扫描。
- 状态探针通过：初始化不读、重叠请求合并、空闲不轮询、预览隔离、取消不发布结果、错误正确退出 loading。此证据不是长期 CPU / 唤醒 / 能耗测量，不承诺绝对零开销。
- Xcode Release 成功：2.0.8 (24)，x86_64 + arm64，`CODE_SIGNING_ALLOWED=NO`。候选为 `build/AGTokenCandidate/Build/Products/Release/QuotAI.app`，不是签名发布包。无新增 Swift 编译警告；已有 Simulator 环境提示和无 AppIntents 的跳过提示不影响 macOS 构建。
- 独立原生 `.app` 预览采用生产视图与 Token store、合成数据源，未接触真实额度。CUA 点击确认：未知日期保持 Unknown；已知日期显示 partial；继续读取后 Unknown 变成确认的 0、选中日期更新为新值；调用次数 120 → 220 → 切 Codex 再回 AG 为 320。不是账户用量测量。
- CUA 滚动后截图：方格、状态说明、保活、底部刷新 / 设置全部可访问，未再被窗口高度裁掉；固定 Settings 按钮实际打开唯一预览 Settings 窗口。
- 最终源码的深色原生 Preview 再次检查通过。离线原生卡片图已目视验收：`build/qa/ag-date-grid-zh-dark-card.png`（中文深色完整合成样例）、`build/qa/ag-date-grid-en-partial-card.png`（英文浅色四模型 / 部分合成样例）；无文本裁切，未知 / 零值可区分。渲染器同时设置 AppKit 与 SwiftUI 外观，避免仅切 SwiftUI 深色导致底色仍为浅色。
- 未用未经授权的系统鼠标事件模拟。CUA 点击验收已通过；独立的纯悬停（无点击）验收没有得到可判定的状态变化，不能写成已通过。
- 检查与日志：`build/ag-date-grid-tests.log`、`build/ag-date-local-probe.log`、`build/ag-date-store-probe.log`、`build/ag-date-grid-release.log`。`git diff --check`、脚本语法及双语 strings 格式检查通过。

## 边界与未执行

- 本机 `/Applications/QuotAI.app` 读回仍为 2.0.7 (22)，保持原安装进程运行。build 24 没有覆盖安装、Git 提交 / 推送或 Release 上传。
- 本次 Preview 和预览 Settings 窗口已退出；原安装版保留运行。真实统计缓存未用于合成 UI 验收。
- 当前窗口证据是独立原生 Preview，不是菜单栏锚点的多屏 / 窄屏真机验收。显示器高度传递及限高有源码依据，锚点实际边缘行为仍待该场景验收。
- 没有启动 Antigravity 为测试产生调用；实际运行中厂商实例联测与长期能耗对比仍未执行。
- 以前 build 23 的 UI 与缓存静止记录保留在 `antigravity-token-qa-2.0.8.md` 作为历史，不替代本次日期和计数证据。
