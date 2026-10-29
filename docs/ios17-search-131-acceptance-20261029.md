# 第131版搜索与繁殖导航：iOS 17 定向验收

搜索空格缺陷与首页进入羊只列表卡顿均已修正，并各自通过受影响路径复核。9 条目标路径目前都有 iOS 17.5 模拟器通过证据；这是复用未受影响的既有结果并补齐最后一项，不是同一提交一次运行 9 项的全量报告。未修改生产牧场数据，未合并或发布。

## 范围与环境

- 核查日期：2026-10-29（北京时间）。基线 main：`f83eba24f34d33497c9826cdb1ef0d7054194eda`。
- iPhone 15 Pro / iOS 17.5 (21F79)，Xcode 26.3 (17C529)，SDK 26.2，Legacy17 测试计划，Debug 隔离构建。
- 本次不是 TestFlight 第131版二进制验收；iOS 17.0、iOS 17 真机未执行。
- iOS 27.2 模拟器与既有真机记录继续引用 [10月28日验收](universal-search-release-20261028.md)，本轮没有重跑，不将其视为 iOS 17 真机证据。
- 没有运行完整单元、性能或 UI 套件。所有后续执行都只选择原来失败的首页导航用例。

## 最终修正与证据

### 搜索末尾空格

原始 `query` 变化会清空结果，但搜索任务身份使用 `normalizedQuery`。追加或删除末尾空格时任务身份不变，结果不会恢复。将观察器改为 `normalizedQuery`，与任务身份一致。实际输入复核通过，22.714 秒；见 [第二轮记录](https://github.com/Jinxed-Liu/esheep/actions/runs/40794162750)。

### 首页进入羊只列表卡顿

原始失败不仅是标题查询失败：点击“在场羊只，12”后页面停留首页、主线程不响应。完整 xcresult 的系统日志显示，点击后 `FarmHomeView` 与 `HerdManagementView` 持续交替报告 `@self changed`，而没有相应羊只源数据或筛选状态更新。首页会在父级导航布局变化中重新构造带谓词的 Query；目标页稳定输入、改入口样式和改标题均未切断循环。

最终在 **iOS 17 的首页入口** 添加 `LegacyFarmHomeEntry` 比较边界：比较账户/牧场对象身份、牧场 ID、加入状态，以及天气/指标展示状态的值快照。相同输入不再重新安装首页查询；子视图自身的 State、Query 和模型观察保留。iOS 18+ 继续使用原有首页实现，原生导航和转场不变。

- 验证提交：`51f65092`。
- [首页单项复核](https://github.com/Jinxed-Liu/esheep/actions/runs/40812302987)：**1 执行、1 通过、0 失败、0 跳过，49.040 秒**；工作流成功。
- 实际通过：首页 → 羊只列表 → QA-001 → 繁殖依据与历史 → 产羔详情；连续三轮逐级返回；最后返回羊只列表和首页，确认控件可点击。
- 未修改测试断言或放宽等待条件。
- 最终清理仅移除临时、限量的 DEBUG `_logChanges()` 诊断调用与 helper，并更新文档；首页修正逻辑与通过候选一致，没有为清理再次运行 UI 测试。
- 静态门禁通过（公开配置与法律占位检查按诊断设置跳过）；这不替代运行验证或真机验收。

## 目标路径覆盖

| 路径 | XCTest 方法 | 通过证据 |
| --- | --- | --- |
| 类别横向切换、键盘打开后末项可见且可点击 | `FarmSearchUITests/testCategoryBarUsesScreenWidthAndLastResultClearsKeyboard` | 第一轮，31.232 秒 |
| 空查询最后一个建议可见且可点击 | `FarmSearchUITests/testDiscoveryOmitsExplanationAndLastSuggestionClearsKeyboard` | 第一轮，13.672 秒 |
| 耳号进入羊只/产羔详情，返回保留查询 | `FarmSearchUITests/testEarTagSearchOpensSheepAndReproductionEventAndRetainsQuery` | 第二轮，25.732 秒 |
| 羊舍及在舍羊只分类 | `FarmSearchUITests/testPenSearchShowsOccupancyAndOpensPenDetail` | 第二轮，15.274 秒 |
| 转群详情、取消修正、日期筛选与清除 | `FarmSearchUITests/testTransferEventDetailAndEventFilterSheet` | 第二轮，26.376 秒 |
| 旧耳号输入、返回保留类别/事件类型/日期限制/查询 | `FarmSearchUITests/testLegacyEarTagSearchRetainsCategoryAndEventFiltersAfterDetails` | 第二轮，40.873 秒 |
| 追加/删除尾部空格后结果保持 | `FarmSearchUITests/testEquivalentNormalizedQueryRetainsSettledResults` | 第二轮，22.714 秒 |
| 搜索入口繁殖历史三轮逐级返回 | `ReproductionNavigationUITests/testSearchProfileHistoryReturnsWithoutDuplicateDetails` | 第二轮，40.790 秒 |
| 首页入口繁殖历史三轮逐级返回 | `ReproductionNavigationUITests/testHomeHerdProfileHistoryReturnsWithoutDuplicateDetails` | 最终单项，49.040 秒 |

日期条件用例验证当天限制与事件类型，不涵盖自定义起止日期逐项编辑。返回 helper 使用 iOS 17 原生返回按钮，保留完整层级断言。键盘用例按导航栏、搜索框与键盘实际位置计算可见区域，仍要求末项完整可见、可点击并验证目标页。

## 历史执行与无效候选

保留失败证据，不将撤回方案计为修复。

| 执行 | 候选/范围 | 结果 |
| --- | --- | --- |
| [40791444492](https://github.com/Jinxed-Liu/esheep/actions/runs/40791444492) | 初始 9 条目标路径 | 2 通过、7 失败、0 跳过 |
| [40794162750](https://github.com/Jinxed-Liu/esheep/actions/runs/40794162750) | 仅复核失败 7 项 | 6 通过、1 首页失败、0 跳过 |
| [40796449012](https://github.com/Jinxed-Liu/esheep/actions/runs/40796449012) | 取消 iOS 17 指标状态回写外层 | 首页失败，182.330 秒；撤回 |
| [40798473281](https://github.com/Jinxed-Liu/esheep/actions/runs/40798473281) | 原生 VStack 首页布局对照 | 首页失败，185.283 秒；撤回 |
| [40804019620](https://github.com/Jinxed-Liu/esheep/actions/runs/40804019620) | 羊只目标页稳定输入 | 首页失败，194.173 秒；撤回 |
| [40806600593](https://github.com/Jinxed-Liu/esheep/actions/runs/40806600593) | `5e918492`，收窄导航闭包捕获 | 首页失败，180.867 秒；撤回 |
| [40808362851](https://github.com/Jinxed-Liu/esheep/actions/runs/40808362851) | `6f87ed02`，iOS 17 直接 NavigationLink | 首页失败，188.558 秒；撤回 |
| [40810074834](https://github.com/Jinxed-Liu/esheep/actions/runs/40810074834) | `dae251dc`，标题单一来源及限量诊断 | 首页失败，189.443 秒；标题改动撤回，原始系统日志确认输入重建循环 |
| [40812302987](https://github.com/Jinxed-Liu/esheep/actions/runs/40812302987) | `51f65092`，稳定 iOS 17 首页入口输入 | 首页通过，49.040 秒，0 跳过 |

第131版早期工作流 [40673426699](https://github.com/Jinxed-Liu/esheep/actions/runs/40673426699) 在运行时下载阶段取消，UI/XCTest 跳过，不计入通过证据。10月25日旧版本记录不包含完整新搜索，也不用于补足本次范围。

## 数据隔离与原始材料

每次启动使用随机 `--design-fixture-id`，仅使用 `--design-acceptance --design-reproduction` 的独立本地测试环境。首页附加 `--design-workspace`，搜索附加 `--design-search`。测试启动分支在正常 `bootstrap.start()` 前返回；数据位于独立 `DesignAcceptance/Reproduction/<UUID>/acceptance.store`，协作存储 `allowsRemoteConnections: false`，种子入口同时验证测试账号身份及 `localOnly` 路由。未访问、修改生产牧场或正式登录状态。

各工作流保存提交、Xcode、SDK、模拟器型号、运行时、精确选择清单、日志、截图与原始 xcresult。视图变化日志是 info 级别，需从原始 xcresult 导出 diagnostics，再对其中的 `system.logarchive` 使用 `log show --info --debug` 读取；常规 app-runtime.log 不包含该级别，不能据其缺失判断没有重建。

本机续修证据保存在工作区 `work/ios17-home-diagnosis/`，编辑前备份在 `work/backups/20261029-102834/`。最终修复集中于 [PR #18](https://github.com/Jinxed-Liu/esheep/pull/18)，保持未合并、未发布。
