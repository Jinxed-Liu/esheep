# 第131版搜索与繁殖导航：iOS 17 定向验收

本次已确认并修复搜索词规范化后结果被清空的问题，相关复核通过。9条目标路径已有8条通过；iOS17首页卡顿仍未解决，最后的稳定目标页候选同样失败并已撤回，不能记为整体通过。未修改生产牧场数据。

## 基线与范围

- 核查日期：2026-10-29（北京时间）。
- 产品代码基线：`f83eba24f34d33497c9826cdb1ef0d7054194eda`，即10月28日最新 main；核查时没有后续提交、开放 PR 或仍在运行的搜索兼容性验证。
- `eSheepNext.xcodeproj/project.pbxproj` 的部署目标为 iOS 17.0，营销版本为3.2；部署目标配置与实际运行验收分别记录。
- 本次验证的是该代码基线的 Debug 隔离测试构建，并非直接操作 TestFlight 第131版二进制或生产牧场。
- 第131版代码原有 iOS 17 工作流 [40673426699](https://github.com/Jinxed-Liu/esheep/actions/runs/40673426699) 在下载运行时阶段取消，UI/XCTest 步骤跳过，不能作为通过证据。
- 10月25日的旧版本通过记录不包含本次新增完整搜索功能，未用于补足此次验收。

## 运行记录

| 环境 | 证据 | 结论 |
| --- | --- | --- |
| iOS 17.5 模拟器，本次 | [40791444492](https://github.com/Jinxed-Liu/esheep/actions/runs/40791444492)，候选 `f0bb59269af15002cae77c5700e30ab21a1d83f8` | 9项执行，2通过、7失败、0跳过；原始失败保留 |
| iOS 17.5 模拟器，失败路径复核 | [40794162750](https://github.com/Jinxed-Liu/esheep/actions/runs/40794162750)，候选 `d0629340178402fa28754c3aa1fcf588cb0da5ee` | 仅复核7项，6通过、1失败、0跳过；首页卡顿仍存在 |
| iOS 17.5 模拟器，首页修正复核 | [40796449012](https://github.com/Jinxed-Liu/esheep/actions/runs/40796449012)，候选 `741dcb2cf87d4a40f601b1579233504e6d4d8d4f` | 1项执行、0通过、1失败、0跳过（182.330秒）；主线程超时仍存在，无效改动撤回 |
| iOS 17.5 模拟器，原生首页布局对照 | [40798473281](https://github.com/Jinxed-Liu/esheep/actions/runs/40798473281)，候选 `8c03cf71dc28bca446ad70be83fc3bf8b674b692` | 1项执行、0通过、1失败、0跳过（185.283秒）；布局对照无效，已撤回 |
| iOS 17.5 模拟器，稳定目标页复核 | [40804019620](https://github.com/Jinxed-Liu/esheep/actions/runs/40804019620)，候选 `ffcb8cc56d349266bba03e9890ee467d0f957437` | 1项执行、0通过、1失败、0跳过（194.173秒）；进入羊只列表时卡顿，未进入三轮往返，无效候选撤回 |
| iOS 27.2 模拟器，既有记录 | [10月28日验收](universal-search-release-20261028.md)：首页、搜索两条繁殖导航，各三轮往返 | 复用原有证据，本次未重复运行 |
| 真实设备，既有记录 | 同上：搜索布局、键盘、筛选、详情及繁殖操作；用户曾确认 Dev 3.2（103）导航正常 | 保留为原有真机记录，不等同于第131版 iOS 17 真机验收 |
| iOS 17.0 模拟器及 iOS 17 真机 | 本次无对应环境 | 未执行，不以17.5或新系统结果替代 |

## 定向测试

手动范围 `search-navigation` 精确选择9项，禁用并行；首页和搜索入口的每条繁殖导航测试内部各执行三轮。没有运行完整单元、性能、助手、海报或其他无关 UI 套件。

| 路径 | XCTest 方法 |
| --- | --- |
| 类别横向切换、键盘打开后末项可见且可点击 | `FarmSearchUITests/testCategoryBarUsesScreenWidthAndLastResultClearsKeyboard` |
| 空查询最后一个建议可见且可点击 | `FarmSearchUITests/testDiscoveryOmitsExplanationAndLastSuggestionClearsKeyboard` |
| 耳号进入羊只/产羔详情，再返回保留查询 | `FarmSearchUITests/testEarTagSearchOpensSheepAndReproductionEventAndRetainsQuery` |
| 羊舍及在舍羊只分类 | `FarmSearchUITests/testPenSearchShowsOccupancyAndOpensPenDetail` |
| 转群详情、取消修正、日期筛选与清除 | `FarmSearchUITests/testTransferEventDetailAndEventFilterSheet` |
| 实际输入旧耳号；返回后保留类别、事件类型、日期限制与查询 | `FarmSearchUITests/testLegacyEarTagSearchRetainsCategoryAndEventFiltersAfterDetails` |
| 搜索词追加/删除尾部空格后结果保持 | `FarmSearchUITests/testEquivalentNormalizedQueryRetainsSettledResults` |
| 首页→羊只→繁殖历史→产羔详情，三轮逐级返回 | `ReproductionNavigationUITests/testHomeHerdProfileHistoryReturnsWithoutDuplicateDetails` |
| 搜索→羊只→繁殖历史→产羔详情，三轮逐级返回 | `ReproductionNavigationUITests/testSearchProfileHistoryReturnsWithoutDuplicateDetails` |

日期保留用例验证当天限制开关和事件类型，不涵盖自定义起止日期逐项编辑。

原键盘用例将搜索框假定为屏幕底部，现按导航栏、搜索框和键盘实际位置计算可见区域，仍要求末项完整可见、可点击并验证点击结果。iOS 17 原生分组列表的缩进不再套用新系统边到边样式断言。

## 隔离与证据

每次启动使用随机 `--design-fixture-id`，仅使用显式 `--design-acceptance --design-reproduction` 的本地测试环境，搜索入口附加 `--design-search`，首页入口附加 `--design-workspace`。`eSheepNextApp` 在正常 `bootstrap.start()` 前退出测试启动分支；`DevelopmentDesignAcceptanceView` 使用独立 `DesignAcceptance/Reproduction/<UUID>/acceptance.store`，协作存储明确设置 `allowsRemoteConnections: false`，不加载或覆盖正式登录状态。种子入口同时验证测试账号身份及 `localOnly` 存储路由。旧耳号 `QA-OLD-001` 和当天产羔时间只写入 DEBUG 搜索样本，未修改生产牧场事实。

工作流保存提交、Xcode、SDK、模拟器型号、运行时版本、精确选择清单、日志、截图和原始 `.xcresult`。数量必须与选择一致，失败或跳过均不能计为通过。修复后的单项复核可用 `search-normalization`，避免重复其他已通过路径。

## 已通过路径与保留的失败证据

第二轮原始 summary 为 `totalTestCount=7 / passedTests=6 / failedTests=1 / skippedTests=0`。与第一轮两个未受影响的键盘用例合并，目前9条目标路径有8条通过，首页入口仍待修正验收。不能把第二轮标记为整体通过。

| 第二轮通过用例 | 时长（秒） |
| --- | ---: |
| 耳号→羊只/产羔详情→返回 | 25.732 |
| 等价规范化查询保留结果 | 22.714 |
| 旧耳号、类别和事件日期条件保留 | 40.873 |
| 羊舍与在舍羊只 | 15.274 |
| 转群详情与日期筛选 | 26.376 |
| 搜索入口繁殖历史三轮逐级返回 | 40.790 |

第二轮 focused artifact 为 `compatibility-gestures-iOS-17-eSheepNextUI-d0629340178402fa28754c3aa1fcf588cb0da5ee`（ID `12863912023`），含 `native-interactions-summary.json`、逐项结果、选择清单、日志、`search-runtime-28150.sample` 与 `search-runtime-stall.png`。原始结果包单独保存为 `search-recovery-xcresult-iOS-17-d0629340178402fa28754c3aa1fcf588cb0da5ee`（ID `12864245436`）。

## 缺陷与最小修正

- 基线两项键盘测试均通过（31.232秒、13.672秒），后续不重复。
- 搜索词追加尾部空格会清空已完成结果，UI测试已复现。原因是原始 `query` 的观察器清空结果，而搜索任务以 `normalizedQuery` 为身份，规范化值相同不会重新运行。修复仅将观察器改为 `normalizedQuery`，与任务身份一致；第二轮22.714秒通过。
- 四条搜索详情返回和一条繁殖搜索返回失败的控件树，均保留原详情且显示原生返回按钮；测试边缘拖动没有触发返回。helper改为点击父页面标题对应的系统返回按钮，不修改产品导航，保留原有逐级返回断言。第二轮四条搜索路径和搜索入口三轮繁殖导航均通过。
- 首页点击“在场羊只，12”后主线程不响应。录屏10秒及60秒仍停留首页，日志多次报告主线程30秒无法完成工作；不是标题断言问题。第二轮仍失败（180.854秒），仅在XCTest报告idle stall后执行的2秒采样与非AX截图确认：页面仍为首页，主线程处于SwiftUI/AttributeGraph布局更新，自动化快照线程等待主线程。采样只有4个主线程样本，无法独自确定具体SwiftUI内部缺陷。第三轮尝试只在iOS17取消将指标详情状态回写外层TabView，仍在点击首页指标后复现超时，因此撤回该无效改动。与发布前 `7b25ebd` 的差异确认，首页主要新增了自定义 `AdaptiveCardStack`；原生VStack布局对照同样复现主线程超时，因此也撤回。第三轮较完整的采样包含 `HerdManagementView.body`、`labelCatalog` 查询及首页视图更新。最后尝试复用项目中 `ReproductionEvidenceView` 已有的稳定输入比较模式，在iOS17首页的羊只目标外增加按账户/牧场对象身份比较的Equatable视图层；相同单项仍卡顿失败，因此该候选也已撤回。最终产品改动仅保留已验证的搜索规范化修复，首页代码与基线一致。现有采样不足以确定根因，首页问题保持未解决状态。
- 运行环境：iPhone 15 Pro / iOS 17.5 (21F79)，Xcode 26.3 (17C529)，SDK 26.2.0，Legacy17测试计划。该工具链与已发布版本使用的Xcode 27.1不同，不能把本次Debug模拟器结果称为已发布二进制的真机验收。

## 交付状态

修复集中于 [PR #18](https://github.com/Jinxed-Liu/esheep/pull/18)。仅搜索规范化缺陷已修复并验证；首页卡顿尚未解决，不将该草稿作为全部兼容性通过的声明。未合并、未发布新版本。最后复查 main 仍为 `f83eba24f34d33497c9826cdb1ef0d7054194eda`。

最后单项原始结果：`totalTestCount=1 / passedTests=0 / failedTests=1 / skippedTests=0`，错误为 `Failed to get matching snapshots: Timed out while evaluating UI query.`。focused artifact ID `12867918037`；原始 xcresult artifact ID `12867499244`。
