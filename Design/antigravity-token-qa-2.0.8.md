# 2.0.8 (23) Antigravity 轻量 Token 统计 · 2026-09-08

> 历史候选记录。下文“无可靠调用时间戳”的结论，以及 build 23 的输入字段计数，已由 [build 24 日期方格核验](antigravity-date-grid-qa-2.0.8.md) 更正；不将旧计数作为当前依据。

状态：功能候选已实现，源码、合成测试、Universal 构建和离线渲染通过。
解锁后已补验真实候选显示、版本读回、关闭后的缓存静止，以及独立原生窗口的生产控件点击；证据边界见下。
未覆盖 `/Applications/QuotAI.app`，未提交、推送或创建 GitHub Release。

## 实现与边界

- 新增 `Core/AntigravityTokenUsage.swift`、`TokenUsageDatabase.swift`、`AntigravityTokenReader.swift`：原生 SQLite 只读源库，按主键限量读取 `gen_metadata`，只解析已知数字字段、模型家族及用于去重的响应标识。
- 不读取步骤正文、标题或工作区路径，不保存原始响应标识、模型标签或元数据。缓存只保存数值、模型家族、哈希和进度，文件权限 0600。
- 新增 `AntigravityTokenStore` / `AntigravityTokenUsageView`，接入 Antigravity 页面打开和显式刷新；原有 Codex 与 Antigravity 额度周期刷新保持独立。
- 不新增轮询、定时器、文件监听、常驻服务、CLI 子进程、网络或模型调用。SQLite 连接在请求结束后释放。
- 单次最多 4 个会话、512 条元数据、768 KiB；源读取循环和 SQL 执行使用 80 ms 工作预算。目录准备、缓存写入及汇总另计，这不是整次请求的硬时限。
- 会话目录最多枚举 2048 个入口 / 512 个数据库；缓存最多 10 万条记录。未完成时明确显示部分统计，由用户继续读取，不自动补全历史。
- 未变化源库不重复解码；变化文件分批重校，处理旧记录改写、删除和会话分叉。冲突副本或未知字段格式不猜测计数。
- 显示本机保留会话的已记录输入＋输出，输出包含思考；缓存读取单列。不是账户总量或账单；内部字段映射未经官方计费核验。没有可靠调用时间戳，不提供每日热力图。

## 已执行验证

### 源码与合成测试

- `swift test`：46 项通过，包括新增的 10 项 Antigravity Token 测试。
- 覆盖数字字段 / 思考不重复计入、分批上限、进程重启续读、未变化库零解码、旧记录修改 / 删除 / 移除文件、跨会话去重 / 冲突排除、坏数据 / 缺标识 / 超大记录 / schema 变化、隐私缓存、批次间变化重校。
- 合成 WAL 测试：写连接保持未提交事务时，读取已提交数据，不阻塞写方；提交后新记录可读。
- 离线无 sidecar 的 WAL 测试：运行态探针为真时拒绝 immutable，不创建源 sidecar；确认离线时读取成功，源文件内容不变。
- 非索引的元数据 schema 被拒绝，不降级为全表扫描。
- `Tools/AntigravityTokenProbe.swift` 隔离状态探针通过：初始化不读、并发刷新合并、空闲不轮询、预览不读真实数据、取消不发布结果、错误恢复 loading 状态。
- `git diff --check` 通过；英文与简体中文资源键及格式占位符测试通过。

### 当前版本本机只读探针

- Antigravity 2.12.2，未为测试启动 Antigravity；只读取已有 `gen_metadata`，使用可自动清理的临时私有缓存。
- 最终代码执行两批：85 ms / 72 ms；读取 444 / 512 条、494137 / 575511 字节，34 个源库仍为部分覆盖，没有为获取完整总量继续扫描。
- `/usr/bin/time -l` 的隔离探针进程记录：0.16 s wall、0.05 s user、0.03 s sys，峰值 RSS 10895360 字节。它不是 QuotAI 常驻进程的增量内存或长期能耗测量；样本受文件缓存及并行构建负载影响。
- 诊断输出不含真实 Token 数值、响应标识或会话路径。日志：`build/ag-tokens-local-probe.log`。

### 构建与渲染

- Xcode Release 构建成功，`CODE_SIGNING_ALLOWED=NO`；产物版本 2.0.8 (23)，包含 x86_64 和 arm64。
- 候选：`build/AGTokenCandidate/Build/Products/Release/QuotAI.app`。这是未签名候选构建，不是已发布安装包。
- 构建环境有无关的 iOS Simulator 版本提示及无 AppIntents 依赖的元数据跳过提示；无新增 Swift 编译警告。
- 离线原生 SwiftUI 渲染已目视检查：英文浅色四模型 / 部分覆盖、中文深色两模型 / 完整样例；卡片、分组、范围说明和底部操作可见。
- 图片：`build/qa/ag-tokens-en-partial.png`、`build/qa/ag-tokens-zh-dark.png`。全部使用合成预览数据，不代表真实账户 UI。
- 渲染器仅将 Antigravity 预览画布增高至 840 pt；生产面板宽度仍为 340 pt。

## 尚未执行

- 原生菜单栏锚点上的完整连续点击、读取中瞬间关闭的取消，以及窄屏 / 多屏高度验收。读取取消已有隔离探针证据，但不是原生弹窗瞬间关闭实测。
- 真正运行中的 Antigravity 实例联测；当前并发 WAL 证据来自合成写连接，不替代厂商应用实测。
- 安装后长期 CPU / 唤醒 / 能耗基线对比。实现没有新增空闲调度，但不承诺绝对零资源开销。
- 签名打包、覆盖安装、Git 提交 / 推送和 GitHub 安装包发布。本机版本读回仍为 2.0.7 (22)。

## 解锁后的交互补验

- CUA 已能读取真实界面，不再是锁屏阻断。按实际执行路径确认测试进程来自 `build/AGTokenCandidate/.../QuotAI.app`；设置“About”页面显示 Version 2.0.8 (23)。
- 真实候选弹窗：Antigravity 未运行，额度明确不可用，但本机 Token 卡片仍有本地统计、缓存读取单列、部分覆盖及未计入记录提示；没有借用 Codex 额度。
- 用户打开原生弹窗后，CUA 获得 Antigravity 页的真实 AX 状态。弹窗在点击外部后收起，直接连续自动点击受到 `noWindowsAvailable` / `timeoutReached` 限制；不把用户操作记成自动化点击通过。
- 生命周期日志确认外部点击后关闭。关闭前后的缓存进度及文件 mtime/size 多次读回保持不变；候选没有在收起后继续补齐历史。短时进程 CPU 读数为 0.0%，不是长期平均能耗证明。
- 为稳定验证控件，增加仅属于 Preview 可执行程序的 `--tokens-qa` 合成数据源。执行 `./script/build_and_run.sh --preview tokens general light`，仍使用生产的 `MenuBarPanelView`、`AntigravityTokenUsageView` 和 `AntigravityTokenStore`；不会读取真实源库或调用额度接口。正式 App 的编译目标不包含这个夹具。
- 独立原生窗口 CUA 实际点击通过：首次显示部分统计 → “Read more” 更新后变成“Refresh”并显示完整状态 → 切 Codex 后 AG 卡片消失 → 切回 AG 只增加一批 → 底部 Refresh 再增加一批。合成调用数依次为 120 / 220 / 320 / 420，与四次预期请求一致。
- 同窗口截图确认双额度组、Token 卡片和底部按钮完整可见；属于原生窗口渲染，不是菜单栏小屏锚点验收。真实 Token 缓存进度在这组合成 UI 测试中保持不变。
- Preview 构建无编译警告，`bash -n script/build_and_run.sh` 和 `git diff --check` 通过。此次新增内容仅为 Preview 测试夹具、脚本入口和文档，生产 App 源码未另作修改。
- 临时验收窗口已退出；测试结束恢复 `/Applications/QuotAI.app` 原安装版运行，不覆盖其文件，不发布 GitHub。

后续：按用户指令决定是否继续活跃 Antigravity / 原生菜单栏边界验收、覆盖安装及 GitHub 发布。
