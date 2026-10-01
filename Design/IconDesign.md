# QuotAI 应用图标

2026-10-01：依据用户反馈重新规划。Claude Opus 5.5 提供设计分析，Codex 核实原始资源、确定方案并完成替换。

## 原因与方案

旧母版虽然带有 Alpha 通道，但 Alpha 最小值为 163，四角实际为不透明黑色。Finder 实际显示了银色底板、黑色方底和深色圆角主体三层边界；复杂刻度和电路线在小尺寸下难以辨认。

新方案用一个粗线条 Q 形额度环表达应用用途：青柠至青色的亮弧、低调的剩余轨道、深蓝圆角底板。取消刻度、准星、球体、描边和外发光。图标外围透明。环的比例是固定的品牌图形，不代表用户当前的实际额度。

`AppIcon-master.png` 是 1024 × 1024 的 PNG 母版。应用图标与界面内 AppMark 采用同一资源，通过 `script/generate_app_icons.sh` 生成 macOS 16/32/128/256/512 的 1x、2x 图标，以及 256/512 的 AppMark。继续兼容项目现有的 macOS 14+ asset catalog，不增加 Icon Composer 依赖。

## 生成提示词

使用内置 imagegen，要求 transparent_background=true。输出归一化为 1024 × 1024，保留透明度。

```text
Create ONE finished production macOS application icon for QuotAI, a quiet utility that tracks remaining AI usage quota. New original design, not a presentation or mockup. Output exactly one square 1024x1024 PNG RGBA with a genuinely transparent outer canvas. The ONLY opaque background is one perfectly centered continuous-curvature rounded-square tile, approximately 824x824 pixels, from x=100 to924 and y=100 to924; deep midnight navy #101B2D with only a very subtle top-to-bottom tonal gradient. No exterior border, no extra backplate, no metallic frame, no black rectangle behind the tile, no drop shadow. Center one bold clean geometric Q, formed as a thick circular quota progress ring with one integrated short rounded diagonal tail pointing down-right. Q ring outer diameter around 530 pixels, thickness about 105 pixels, centered visually around 500,485. About 75% of the ring is a restrained smooth bright gradient from chartreuse #C6F432 at the upper-left through mint to cyan #22D3EE at the lower-right. The remaining quarter is a muted slate-blue track of exactly the same thickness, with a small clear separation between track and the bright arc so it reads as quota remaining. Tail must connect seamlessly to the ring, be cyan, same thickness, approximately 130 pixels long and rounded at its end, extending down-right to around 715,700. The silhouette must clearly read as Q even at 16px. Crisp calm flat dimensional icon with minimal soft material shading, no bloom or glow. Confident simple shapes with generous breathing room. NO radar, concentric rings, circuit lines, ticks, crosshairs, dot, orb, lettering, wordmark, extra glyphs, sparkles, UI, perspective or text. Strict front view. The outside of the navy tile must have alpha=0, including the corners and all canvas margins. Deliver the icon alone at full resolution on transparent background.
```

## 验收范围

- 检查全部资源尺寸和四角透明度。
- 检查 16/32/64/128px 缩小后的 Q 形辨识度。
- 检查 Universal Release 构建与签名。
- 替换本机安装版后，检查 Finder 实际图标和应用内标识。
- 本次为本机图标替换，不自动发布 GitHub Release。

## 本次结果

- 12 个 asset 槽的尺寸和四角透明度全部通过；16/32/128px 实际 PNG 已查看。
- 独立目录中的 Universal Release 构建成功；候选与安装版均通过严格、递归签名校验，仍采用项目现有的 ad-hoc 签名。
- 本机 `/Applications/QuotAI.app` 已更新图标资源并重启，版本保持 2.1.0（37）。更新前后主程序去除签名后的 SHA-256 相同，程序代码没有变化。
- Finder 的安装路径、信息窗口小图标和大图预览已通过 CUA 实际检查；随后直接检查 Applications 文件夹的图标视图，并取消选择以排除选中高亮：QuotAI 与相邻应用正常对齐，旧银色套框与不透明黑色方底消失。
- 面板和关于页通过中文深色的原生离线渲染检查；这是预览证据。CUA 对安装版菜单栏应用的直接读取超时，未将这项写成安装版弹窗验收。安装版 Assets.car 与候选文件的哈希一致。
- Opus 5.5 对最终 PNG 的只读复核结论为可以采用；其意见属于设计建议，Finder 实际验收由 Codex 完成。
- 安装备份：`build/InstallBackups/QuotAI-icon-before-20261001-221332/`；构建、资源、模型调用与安装读回证据：`build/qa/icon-redesign/`。

## 2026-10-02 更新覆盖修复

2.1.1 从尚未提交新图标的隔离分支打包，覆盖了本机已采用的图标。2.1.2（39）将上述已确认的母版、12 个资源槽和生成脚本纳入源码，并重新安装、发布。
候选包的 `AppIcon.icns` 与 `Assets.car` 和此前新图标安装记录的哈希完全相同；Finder 安装路径、版本、小图标及大图预览已重新读回。
验收证据位于 `build/qa/icon-restore-2.1.2/`，更新前应用与偏好备份位于 `build/InstallBackups/QuotAI-before-2.1.2-20261002-011247/`。
