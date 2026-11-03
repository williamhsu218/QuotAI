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

- GitHub Actions macOS 26 runner（[运行 41576510301](https://github.com/williamhsu218/QuotAI/actions/runs/41576510301)）：
  123 项核心测试通过；Debug 构建通过；隔离探针全部通过，其中新增的 `emptyCredits` 模式验证了两种情况：
  没有历史重置卡时只读取一次，有历史重置卡时会确认一次；Universal Release 打包与 ad-hoc 签名检查通过，主程序包含 x86_64 和 arm64。
- 新增 3 项安装检测缓存测试；移除 8 项只覆盖已删除代码的测试，核心测试由 128 项变为 123 项。
- 尚未进行：中英文与明暗外观的原生面板检查、非北京时区下的重置时间显示检查、已安装 App 的刷新与升级读回；
  CI 产出的安装包未在本机安装验证。
