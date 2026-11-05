# iOS 17 / iOS 18 兼容性续查（2026-11-05）

本轮发现并修复了头像展开后点击区域和内容占位仍停留在 100 点宽的布局缺陷。iOS 17.5 与 iOS 18.6 各 6 条目标路径现均有通过证据：5 条复用首轮通过结果，头像在修复后单独通过；较新系统 iOS 26.5 的头像单项也通过。没有重跑完整套件，未合并或发布。

## 基线与范围

- 远端主线：`1a66698979fff1cddaa6071d071a8464fee583a9`。已现场确认 PR #18 合并；本机原始主线仍为 `f83eba24`，本轮在独立 worktree 工作，没有覆盖原始工作区。
- 检查起点的 iOS App、Widget、ESMotion、工程设置、测试计划及 XCTest 源码与上次最终候选 `02a8732b` 完全一致。既有 iOS 17 搜索和首页证据继续有效，见 [10 月 29 日记录](ios17-search-131-acceptance-20261029.md)。本轮后续仅修改头像头部的宽度来源。
- 本轮检查 API 版本边界、类的存储类型、主导航、滚动与头像、输入框、SwiftData 迁移及本地清理；没有扩大为全量回归或发布验收。
- 本机 Xcode 27.2 (27B52)，已安装的模拟器只有 iOS 27.0 和 27.1；旧系统运行验证使用 GitHub 托管 macOS 15 / Xcode 26.3。
- 结束时原主工作区出现另行进行中的 AI 助手与 Web 未提交改动（包括新的 provider 文件）。这些改动已原样保留，不在本轮独立分支和上述运行证据内。

## 源码复核

| 检查部位 | iOS 17 | iOS 18 | 复核结果 |
| --- | --- | --- | --- |
| App、Widget、测试目标、ESMotion 的最低版本 | 17.0 / `.v17` | 同一二进制 | 工程与本地包声明一致 |
| `FarmWorkspaceView` 主导航 | 原生 `TabView` / `tabItem`；首页 `LegacyFarmHomeEntry.equatable()` | 原生 `Tab`；原有首页 | 版本分支及上次卡顿修复保留 |
| 搜索结果失效 | 观察 `normalizedQuery` | 同左 | 与搜索任务身份一致，未恢复原有空格缺陷 |
| `SettingsHomeView` 头像滚动 | 观察现有 `UIScrollView`；保留 delegate 和手势 | `ScrollPosition`、滚动几何及阶段回调 | `ScrollPosition` 存储经 `Any` 擦除，避免旧系统类元数据枚举触碰新类型 |
| 工具栏、玻璃效果、安全区和滚动边缘 | 旧系统原生 API / Material | iOS 18 工具栏 API；iOS 26 效果仍受保护 | 未发现本轮新增的未保护调用 |
| 对话输入框与滚动区域 | 旧版文字/光标隐藏及 UIKit 几何观察 | 原生滚动几何 | 新系统路径保留；分别运行输入与后台恢复检查 |
| ESMotion 转场与释放 | 原生 NavigationStack；无 `isolated deinit` | 原生 zoom 转场 | iOS 18.4 运行时依赖没有重新引入 |
| SwiftData 版本迁移 | 每个历史 schema 边界使用显式 custom stage | lightweight stage | 两条路径均保留，本轮没有改数据迁移逻辑 |
| 本地持久历史清理 | 跳过不支持的 history API | `HistoryDescriptor` / `deleteHistory` | API 及类型均在 iOS 18 检查内部 |
| 新版系统图标 | `CompatibilitySymbol` 回退 | 优先加载当前系统可用图标 | 已知 trianglehead 图标均有旧图标回退 |

以上是源码复核结论；实际 UI 检查随后发现头像布局缺陷，见下文。历史数据库升级、账号登录、真实云端同步及所有业务页面没有在本轮逐项运行验收。

## 头像布局缺陷与修正

首轮两个系统都在首次下拉后的尺寸检查失败。日志证明手势已触发 `offset-expand`，状态达到 `expanded`，`expansion=1`；失败截图也显示图片已经展开到 393 点宽。与此同时，两个系统的可访问性层级均显示 `account-avatar-entry` 仍为 `{{146.7, 0.0}, {100.0, 100.0}}`，下面的账户设置行从约 198 点开始，已被大图覆盖。因此这是实际的点击区域和内容占位错误，不能靠放宽等待或删除断言解决。

`SettingsAvatarHeader` 优先使用其背景探针测得的 `metrics.width`，但自身又用该宽度设置 frame。初始 100 点宽度因而反馈到自身并固定下来；可视图片的 overlay 则正确使用外层 393 点宽度。10 月 28 日对局部可视区域的适配把探针宽度从 window 改成 view bounds，暴露了这一反馈问题。

修正：头部使用 coordinator 中由静止 overlay 测得的 `availableWidth`；删除头部把自己宽度回写到该共享值的回调。图片、点击区域、展开后的内容占位现在使用同一外层宽度。没有使用全局屏幕宽度，没有修改动画插值、下拉阈值、导航或测试断言。

修复提交：`5418c728`。后续仅重跑两个旧系统失败的头像用例，并在较新系统运行同一头像用例以检查共用布局。

## 验证流程修正

原手动流程只有 iOS 17 和较新系统矩阵，不能单独证明 iOS 18 兼容性。本轮为 `ios-platform-gestures.yml` 增加 `runtimes` 选项：`default`、`ios17`、`ios18`、`ios17-ios18`、`ios17-ios18-ios26`；默认仍沿用原来的范围。iOS 18 使用支持该系统的 iPhone 15 Pro，测试计划记录为 `ModernUI`；iOS 17 使用 `Legacy17`。新增 `avatar-layout` 单项范围用于复核本轮失败。

新增 `platform-core` 范围，精确选择以下 6 项，并要求发现数等于 6、无失败、无跳过。两个系统运行同一提交，保存日志、运行环境、精确方法清单、截图和原始 xcresult。

1. 头像两次下拉、关闭大图后恢复布局及设置页导航。
2. 首页 → 羊只列表 → 羊只详情 → 繁殖历史 → 产羔详情，连续三轮逐级返回。
3. 搜索追加/删除末尾空格后保留结果。
4. 搜索分类横向切换及键盘打开时最后一条结果可见、可点击。
5. 输入框 Return 换行、发送后保存并重新打开会话。
6. 回复生成中短暂切后台，回到前台后继续完成，原始消息不重复。

分支 `codex/ios17-ios18-compatibility` 已排除 push 自动运行；仅手动触发所选检查，没有创建触发完整检查的 PR，也没有合并或发布。

## 本轮运行证据

- 首轮候选：`53e7a4f63729a3a09fd435d04f1ebd19c8fae232`，此时仅工作流调整，未修改产品 Swift 代码。
- [首轮执行 41933627291](https://github.com/Jinxed-Liu/esheep/actions/runs/41933627291)：`platform-core` / `ios17-ios18`。iOS 17.5 (21F79) 与 iOS 18.6 (22G86)，均为 iPhone 15 Pro / Xcode 26.3 (17C529)、SDK 26.2。每个系统 6 执行、5 通过、1 头像失败、0 跳过。
- iOS 18 步骤请求下载 18.5，最终选择主机已有的最高稳定 iOS 18 运行时 18.6；以保存的实际 runtime selection 和 xcresult 为准，不将其记为 18.5。
- [头像单项复核 41936961399](https://github.com/Jinxed-Liu/esheep/actions/runs/41936961399)：修复候选 `5418c7281da0e75ab92954cb7fda9bf6fe041adb`，`avatar-layout` / `ios17-ios18-ios26`。三个 job 均成功；首轮通过的 10 项未重跑。
- 所有头像复核均为 1 执行、1 通过、0 失败、0 跳过，原测试方法、断言和等待条件没有修改：

| 实际系统 / 设备 | Xcode / SDK | 测试计划 | 头像单项耗时 |
| --- | --- | --- | --- |
| iOS 17.5 (21F79) / iPhone 15 Pro | 26.3 (17C529) / 26.2 | Legacy17 | 44.721 秒 |
| iOS 18.6 (22G86) / iPhone 15 Pro | 26.3 (17C529) / 26.2 | ModernUI | 89.178 秒 |
| iOS 26.5 (23F77) / iPhone 17 Pro | 26.6 (17F113) / 26.5 | ModernUI | 84.387 秒 |

修复后截图及可访问性层级已人工复核：iOS 17.5 / 18.6 的头像点击区域是 `{{0, 0}, {393, 393}}`，iOS 26.5 是 `{{0, 0}, {402, 402}}`，与可见图片宽度一致；账户设置行出现在图片下方。大图关闭后头像恢复折叠尺寸，进入修改名称页再逐级返回的断言均通过。另已复核首轮两系统的搜索末项与两行输入框截图。

这些结果是首轮与头像定向复核的组合证据，不是修复后重新执行全部 12 项的报告。首轮每个系统的 1 次头像失败仍保留，不从记录中删除。

其他本地检查：

- 静态门禁通过：`VERIFY_PUBLIC_CONFIG=0 VERIFY_ALLOW_LEGAL_PLACEHOLDERS=1 ./tools/verify_local.sh static`。跳过本机公开配置值检查，允许现有法律占位符；这不是发布配置验收。
- 兼容性验证工具 66 项测试通过；最终工作流 Shell 语法、8 个嵌入 Python 块、60 个运行矩阵组合以及 6 项/头像 1 项的方法选择校验通过。头像源文件 Swift 语法检查和 diff 空白检查通过。
- 没有运行完整单元、性能或 UI 套件；没有用 iOS 27 的运行结果替代 iOS 17 / 18。

11 月 4 日主线上的 iOS 17 检查 `41857572086` 和较新系统检查 `41857572171` 均未执行任何步骤。GitHub 注释指出托管 Runner 未分配成功，并提示 macOS arm64 容量不足。这两次失败不能计为应用测试失败，也不能计为通过。

## 数据隔离与验收边界

所选用例均使用 `--design-acceptance`，在正常 `bootstrap.start()` 前退出；合成牧场使用 `localOnly`，协作存储 `allowsRemoteConnections: false`。搜索、首页与头像使用 UUID 隔离目录；对话用例使用独立 `DesignAcceptance/InsightOfflineSend` 存储和离线 responder。所有写入仅发生在临时模拟器中的测试数据，未读取或更改生产牧场。

本轮结果不代表 iOS 17.0、iOS 18.0、真机或 TestFlight / Production 二进制已经验收。完整升级迁移、真实网络/云端同步、相机和麦克风、通知及付费流程仍需各自对应的证据。

## 本机材料

- 工作区：`/Users/jinxliu/.codex/worktrees/ios17-ios18-compatibility/eSheepNext`
- 工作流修改前备份：`backups/20261105-072336-skill-backup/`
- 头像修复前备份：`backups/20261105-074931-skill-backup/`
- 日志与结构校验：`work/ios17-ios18-review/`
- 首轮汇总：`work/ios17-ios18-review/baseline-evidence.json`
- 修复汇总：`work/ios17-ios18-review/repair-evidence.json`
- 首轮和修复后的日志、截图、执行数与工具链来自两个 GitHub run 的 artifact，原始 xcresult 同时保存在各自的 GitHub artifact 中。

复现本轮定向检查：

```bash
gh workflow run ios-platform-gestures.yml \
  --ref codex/ios17-ios18-compatibility \
  -f scope=platform-core -f runtimes=ios17-ios18

# 只复核头像修复
gh workflow run ios-platform-gestures.yml \
  --ref codex/ios17-ios18-compatibility \
  -f scope=avatar-layout -f runtimes=ios17-ios18-ios26
```
