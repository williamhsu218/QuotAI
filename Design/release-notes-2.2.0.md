# QuotAI 2.2.0

修正时区显示、降低刷新开销，清理遗留代码并接入持续集成。

- 额度重置、重置卡到期与 Claude 查询时间改为跟随系统时区（含之后的系统时区变更），不再固定为北京时间；
  位于北京时间的用户显示不变，Claude 卡片不再显示“北京时间”标签。
- Codex 刷新仅在上次结果有重置卡、本次返回为空时才确认读取一次；原本没有重置卡的账户每次刷新只启动一次
  `codex app-server`，不再额外等待 2 秒。
- Antigravity 安装检测缓存应用目录扫描结果：目录变化或超过 5 分钟才重新扫描，已找到的安装每次仍会校验，
  卸载或损坏可立即识别。菜单栏定时检查、打开面板和每次刷新不再在主线程重复读取全部应用的 Info.plist。
- 移除未使用的 Claude 会话选择、旧 `claude` 来源枚举值和不再调用的菜单栏标题与 7 日分桶辅助方法；
  旧版本保存的 `claude` 来源偏好仍回退为 Codex，且不改写原值。
- 新增 GitHub Actions：每次推送执行核心测试、Debug 构建、隔离探针与 Universal Release 打包；
  新增 `script/run_probes.sh` 统一运行隔离探针。
- 文档更新时区口径与版本说明链接；旧版本说明改由 GitHub Releases 保存。

提供 macOS 14+ 的 Apple Silicon / Intel Universal 包，采用 ad-hoc 签名，未进行 Developer ID 签名或公证。

## 验证

- 待 CI 结果回填：核心测试、Debug 构建、隔离探针（含新增 `emptyCredits` 模式）与 Universal Release 打包。
- 尚未进行：中英文与明暗外观的原生面板检查、非北京时区下的重置时间显示检查、已安装 App 的刷新与升级读回。
