# iPhone Duo 适配与验收记录

日期：2026-10-25。基线：`97e5a2df`；工作分支：`codex/sync-recovery-startup-order`。

后续新增刘海头像融合动画，代码与 33 项自动测试已完成；用户选择暂缓普通 iPhone 视觉验收。该增量与下文主适配版本分别记录，见 [刘海动画验证记录](avatar-notch-animation-2026-10-25.md)。

后续顺序调整：按用户要求，竖向侧栏改为头像在上、牧场名称胶囊在下；横向工具栏保留原位置。名称滚动、高度限制、独立搜索与业务动作未改。该小改动 Debug 构建通过（`avatar-order-build.log`），Duo 闭合、展开均已视觉确认，头像点击可进入设置页并返回。最新截图为 `ui-evidence/avatar-above-farm-home.jpg`、`avatar-above-farm-open.png`。下文的 Release、52 项 XCTest 和原截图记录属于此次顺序调整前的主适配版本，本次未重复 Release 或 XCTest。

## 范围与构建要求

本次处理窗口动态变化、竖向系统栏、安全区、卡片重排和编辑状态保留。业务事实、云命令、同步与生产数据没有改动；版本号、构建号和分发状态没有改动。

本机使用 Xcode 27.1（27A9275）、iOS 27.1 SDK，Duo 模拟器运行 iOS 27.1（24A94425）。最低系统版本仍为 iOS 26.1，设备族仍为 iPhone / iPad。新 API 同时有 SDK 条件编译与运行版本检查；未在 Xcode 26.6 上实际编译。

Apple 要求使用 Xcode 27.1 重新编译以采用 Duo 的完整原生布局，并检查系统栏竖向排列后的内容。旧 SDK 编译保护只保证旧构建路径不引用新符号，不会让旧 SDK 的产物获得 Duo 原生布局。正式分发构建应使用 Xcode 27.1 或之后的合适正式版本。[Apple 适配指南](https://developer.apple.com/iphone-duo/prepare/)

## 修改与原因

| 区域 | 原问题 | 本次处理 |
| --- | --- | --- |
| 主导航 | 基线在 Duo 展开后，独立搜索入口形成巨大搜索玻璃层，遮住主体及其余入口 | 保留原 `.search` role 和选中即激活搜索行为；将搜索框交给搜索页的 NavigationStack 容器，使用系统默认位置，取消固定顶部 drawer。闭合/展开首页无额外搜索框，独立按钮及自动激活已实测 |
| 牧场与头像入口 | 用户要求头像和牧场名称放在侧边；名称用加长胶囊，超长时内部滚动且不能挤占其他组件 | 两项使用系统 verticalPreferred 轴策略。头像仍为圆形；名称用 44pt 宽的原生纵向玻璃胶囊，总高 132～160pt，名称视口限定 76～104pt，超长内容在内部上下滚动。底部独立 44pt 菜单按钮负责切换牧场，避免 Menu 吞掉滚动手势；横栏仍为单行菜单，空间不足时沿用系统 overflow |
| 首页、工作台 | 窄屏纵向卡片直接铺满展开后的大屏 | 同一内容树按当前可用宽度重排；两列卡片在纵向折叠区域留白；空间不足或无障碍字号使用单列 |
| 账号头像 | 使用整个窗口宽度计算局部内容，竖栏下头像、姓名及点击区偏移；状态栏高度被当成顶部间距 | 使用当前视图宽度和所属窗口实时顶部安全区；竖栏环境停用顶部中央装饰融合，保留头像查看及更换入口 |
| AI 附件菜单、分析选择器 | 自定义窗口内容忽略安全区；窗口锚点没有转换到安全区内局部坐标 | 内容遵守自身安全区，统一锚点坐标；面板宽高受可用区域及键盘上方空间限制，长内容可滚动 |
| AI 面板跨折叠 | 实测强度面板打开后闭合设备，主线程陷入窗口几何反馈循环，应用持续白屏 | 删除两个浮层对 owner.frame 的四处手工复制，窗口尺寸由同一 UIWindowScene 管理；分析面板补上 reconcile 重入保护。修复后强度、附件两个面板均通过半展开→旋转→闭合回归，同一进程 CPU 回落至 0.0%，面板可关闭，草稿保留且可继续输入 |
| 海报编辑器 | 预览和编辑面板始终竖排，较矮窗口可压缩控件 | 按当前 sheet 空间在横排和竖排间重排；保留同一编辑状态、选择和撤销栈；控件滚动、预览按实际空间缩放 |

`AdaptiveCardStack` 的折叠留白保证仅覆盖显式分配到 leading / trailing 的卡片。首页天气、指标、事件入口和同步状态仍为通栏，不声称所有内容都围绕折叠区域分列。

保留现有全屏照片、天气背景和原生相机包装；前景按钮仍由安全区或原生控制器管理。没有以删除 iPad 支持、锁定方向或 `UIRequiresFullScreen` 来回避动态尺寸。

## 自动验证

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| 布局、头像、海报 Debug build-for-testing | 通过 | `work/iphone-duo-20261025/final-test-build.log` |
| 保留独立搜索的 Debug 构建 | 通过 | `work/iphone-duo-20261025/search-container-build.log` |
| 最终胶囊、滚动与浮层修复 Debug 构建 | 通过 | `work/iphone-duo-20261025/scroll-capsule-fold-fix-build.log` |
| 最终 App 的 Duo 定向 XCTest | 52 通过、0 失败、0 跳过；无 runtime warnings | `work/iphone-duo-20261025/duo-final-regressions.xcresult`、`duo-final-regressions-summary.json` |
| Release 通用 iOS 无签名构建 | 通过，包含主 App 与 Widget；日志没有 warning / error | `work/iphone-duo-20261025/release-verified-build.log` |
| Diff 格式检查 | 通过 | `git diff --check` |
| 源码复核 | 所有变更文件已检查，未发现新的阻断问题 | `work/iphone-duo-20261025/resizability-audit.md` |

52 项测试分别为 `CardColumnLayoutTests` 6 项、`SettingsAvatarIslandGeometryTests` 9 项、`AccountAvatarInteractionTests` 17 项、`SheepSharePosterTests` 20 项。新增测试覆盖窄宽度回退、均分列、不对称活动折叠区域、非活动折叠区域、横向折叠区域和折叠侧空间不足。

最终回归通过 `test-without-building` 在上述 Duo 上运行现有四组测试包，宿主为最新 Debug App。该宿主的主执行文件与 `eSheepNext.debug.dylib` SHA-256 均与交互验收包一致，记录在 `final-debug-binary-match.json`。测试完成后已重新打开隔离样例。

Debug / Release 产物均回读为 Xcode `27A9275`、SDK `27.1`、最低 iOS `26.1`、设备族 `[1, 2]`，保留多场景配置和 iPad 四个方向，没有 `UIRequiresFullScreen`。版本仍为 `3.2 (36)`。产物配置见 `final-built-configuration.json`。Release 构建成功和本地 bundle 校验不等于签名归档、App Store Connect 上传验证或审核通过。

完整 `static` 门禁未通过：首次停在本机缺少 `Config/StagingEnvironment.local.xcconfig`；跳过本地配置值检查后，停在仓库已有的运营者发布占位符。此前的本地化、checkpoint schema、历史裁剪边界、相关脚本单测、云品牌边界、89/89 命令覆盖和隐私 plist 校验通过。未填造运营主体资料，也未将 Staging 指向 Production。日志分别为 `static-check.log` 和 `static-without-local-config.log`。

未执行完整三配置 iOS 门禁、全量 XCTest、Hosted CI、签名归档、上传或审核。

## 模拟器交互验收

交互使用 `--design-acceptance` 隔离样例，原生产数据和云写入流程不参与。最终交互包是 `work/iphone-duo-20261025/scroll-capsule-fold-fix.app`，模拟器 UUID 为 `37E36398-C104-40B7-92FB-1AA295544F0C`。截图位于 `work/iphone-duo-20261025/ui-evidence/`。

| 流程 | 实际观察 | 证据 |
| --- | --- | --- |
| 独立搜索 | 点击独立搜索按钮自动激活；搜索 `QA-010` 得到样例羊只；闭合、展开、半展开、旋转后查询与结果保留；退出回到首页 | `search-container-open-home.png`、`search-container-open-search-active.png` 及同前缀截图；搜索容器代码此后未改 |
| 首页和工作台 | 大屏两列，小屏单列；入口可点击，没有原来的巨型搜索玻璃遮罩。最终组合的默认首页在闭合、展开均保持名称胶囊、头像、主导航与独立搜索互不碰撞 | `candidate-final-closed-home.png`、`candidate-final-open-home.png`；工作台过程详见 `ui-evidence/verification-notes.md` |
| 账号与头像 | 头像、姓名以安全区内内容居中；点击头像可进入详情，展开后仍可见 | `final-closed-account.png`、`final-closed-avatar-detail.png`、`final-open-avatar-detail.png`；此处仅验证头像组件 |
| 海报编辑器 | 未保存的实际文字 `QA-D\u2006u` 和画布在展开→闭合→展开后保留，编辑控件可访问 | `poster-closed-draft-retained.*`、`poster-open-draft-retained.*`；没有保存模板或分享 |
| AI 分析强度 | 方案模式输入草稿 `24680`，半展开→右旋转→打开强度面板→闭合；同一进程 PID 76356 CPU 回落至 0.0%，面板可关闭，继续输入后草稿为 `2468013579` | `candidate-ai-strength-closed.png`、`candidate-ai-draft-retained.png` |
| AI 附件菜单 | 同一进程打开附件菜单后跨半展开、旋转、闭合，菜单完整可见且可关闭；CPU 回落至 0.0%，上述草稿保留 | `candidate-ai-attachment-closed.png` |
| 超长牧场名称 | 40 字测试名称在胶囊内从开头“内蒙古呼伦……”拖至末尾“……试验基地东区一号牧场”；胶囊高度、头像和导航位置不变，拖动不误开菜单。随后独立点击底部箭头，原牧场菜单打开 | `candidate-long-name-before-visible-hub.png`、`candidate-long-name-after-visible-hub.png`、`candidate-long-name-menu-visible-hub.png` |

此前普通搜索 Tab、额外首页搜索框、圆形名称、圆角矩形名称方案均已撤销，相应中间截图不作为最终导航或样式验收。`final-*` 文件名本身不表示最终组合版本；组件证据按上表限定。未完成无障碍最大字号、软件键盘全部姿态、Duo 真机及外设键盘验收。

超长名称仅在 DEBUG 隔离样例中生成，使用 `--design-acceptance --design-fixture-id <新的 UUID> --design-farm-name <测试名称>`。名称参数必须非空且带有效隔离 UUID，不修改现有样例或真实牧场；真实牧场复制入口仍沿用原流程。

原生牧场菜单仍可能对超长标题显示省略号，完整名称保留在可滚动胶囊与无障碍标签中。长名测试期间部分 `simctl` 截图为黑屏、工具曾因前台状态变化超时，这些文件不计为通过；上表使用实际可见的 Device Hub 前后截图和独立点击结果。

## 上架边界和恢复

当前证据区分源码、编译、自动测试、模拟器交互与 Apple 分发；没有 Duo 真机验收或 App Store 审核通过结论。正式发布仍应沿用仓库发布门禁，核验当次 SHA、Xcode 版本、签名、配置及上传后处理结果。

Apple 2026-10-05 的公告表示，2027 年 4 月起提交应用需包含 Duo 截图。这是后续商品页素材要求，不能以本次开发验收截图替代正式素材制作和提交。[Apple 公告](https://developer.apple.com/news/?id=kkphp5qo)

改动前源码备份：`work/iphone-duo-20261023/source-before.tar.gz`。最终 11 个变更源码文件另存为 `work/iphone-duo-20261025/verified-code-snapshot.tar.gz`，逐文件 SHA-256 见 `verified-code-manifest.json`。原有未跟踪 `error.log` 和 `work/` 内容保留；本次新增证据也保存在 `work/`，不应纳入发布包。
