# 2026-09-26 代码清理与运行效率检查

本轮从干净的 `main`、提交 `f5b295f` 开始。检查范围包括 iOS、Widget、Web、身份服务、云协议静态门禁和现有测试。审查采用类型引用、入口追踪、运行热点读取和回归测试；不是逐行形式化验证，也不代表所有历史兼容代码都可以删除。

## 已处理的问题

| 问题 | 证据与原行为 | 本轮处理 |
| --- | --- | --- |
| 无入口的旧界面和辅助类型 | 六个根类型在应用、Widget、测试 Swift 源码中只有定义，没有初始化或类型引用；逐一核对当前导航入口 | 删除六组界面及其专用辅助类型，共 705 行（含相邻空白） |
| 全局搜索保存所有匹配项、重复比较可见结果 | `FarmSearchEngine` 先 `compactMap` 生成全部匹配数组，再对每项线性查找前 50 条中的插入位置 | 改为流式计数与有界结果集合；较差候选只与末项比较，需要插入时二分定位 |
| 表单耳号搜索重复比较、极大 limit 预分配 | `SheepEarTagSearchMatcher` 对每个命中扫描前 8 条，直接按传入 limit 申请容量 | 复用有界搜索集合，分配量同时受真实候选数量约束 |
| TMR 批次页重复遍历流水 | 每一批次都对全部 `movements` 过滤一次；原查询先读取所有牧场再筛选 | 两个 Query 限定当前牧场与有效记录；按批次分组一次，沿用 `TMRCalculator.batchBalance` 计算 Decimal 余额 |
| 待盘槽汇总被连续保存反复触发 | 每次 `ModelContext.didSave` 都立即增加任务版本并重建汇总 | 保存停止 300 ms 后合并刷新；首次读取和原保存通知入口保留 |
| 九个云队列测试缺少设备初始化前置条件 | 改动前 10:21 编译的测试二进制同样复现九个 `requiresCloudStatus` 失败；公共 fixture 仅插入牧场状态，未初始化设备序号水位 | 修正测试 fixture，测试后移除对应随机 ID 的临时 Keychain 项；新增未验证时拒绝写入、验证后遵从云端序号下限的测试，生产保护逻辑不变 |

搜索仍保留精确匹配、前缀匹配、包含匹配、品种匹配的优先级，自然顺序及 UUID 决胜规则不变。总命中数继续包含未显示的结果，表单排除已选羊只的规则不变。

有界集合的存储为 `O(min(k,n))`；新候选淘汰比较为常数次，插入定位为 `O(log k)`，数组移动仍为 `O(k)`。因此不把该实现夸称为所有输入下的 `O(n log k)`。TMR 列表的流水扫描从每批次一次变为分组一次；原余额取整、负数、撤销流水和有效记录语义继续使用原计算器。

## 删除清单与保留的入口

| 删除的根类型 | 同时删除的专用类型 | 当前实际入口或边界 |
| --- | --- | --- |
| `GlassCard` | 无 | 无任何调用的旧视觉包装；现有卡片不变 |
| `FarmWeatherPanel` | 内嵌加载状态 | 首页使用 `FarmWeatherHero`；天气仓库与位置设置保留 |
| `SheepRecordHistoryView` | `RecordDeletionTarget` | `HerdViews` 使用 `SheepRecordHistoryScreen`；修正、撤销、恢复服务保留 |
| `FarmRecordsView` | `PendingCareReminderDestination` | `FarmWorkspaceView` 使用 `FarmWorkbenchView`；后者负责录入与提醒导航 |
| `FeedingStartView` | 无 | 投喂操作、待盘槽和历史入口位于 `FarmWorkbenchView` |
| `RecipeLibraryView` | `RecipeLineInput`、`FeedRecipeEditorView` | 当前入口使用 TMR 配方库；配方模型、命令、Excel 导入和历史数据全部保留 |

这部分删除主要减少维护与编译负担。被删除的类型原本没有运行入口，不能把删除行数换算成运行速度收益。

## 继续核实的候选

单次引用扫描还返回 16 个类型，其中 `eSheepNextApp`、`ESheepNextWidgetBundle` 和 `ESheepShortcuts` 是系统入口，不能作为死代码处理。其余候选尚未纳入删除范围：

- `LegacyMigrationCheckView`、`MigrationWorkspaceView`、`ESheepCloudLegacyDomainBridge`：旧数据迁移、修复工具和兼容边界，应单独检查运维与恢复路径。
- `SupabaseEntitlementClient`、`SupabaseFarmJoinService`、`ProximityInvitationController`：授权、入场和近距离邀请候选；还需与现行云服务及部署兼容周期对照。
- `CloudRecordType`、`CloudRebuildResult`、`FarmPlanStatus`、`FarmCreationEntitlementError`、`LocalStorageCategory`：协议、状态和诊断候选，单次引用不自动等于可删除的数据契约。
- `InventoryManagementView`、`LocalFarmAssistant`：旧库存界面和本地问答候选，后续可分别核对现行健康库存入口、Insight 工具与测试契约。
- Web 的 `FeaturePages.jsx` 没有进入当前入口静态图，但文件明确承担兼容导出；各页面已独立分包，本轮保留该兼容层。

还发现未计入本次性能结论的候选：健康/繁殖表单的嵌套记录筛选、其他 TMR 页面全表 Query、部分摘要读取完整历史。它们需要按真实数据规模和交互抓取耗时，不能机械替换为缓存或移除历史记录。旧 Identity Worker 和 CloudKit/迁移路径也不能仅根据名称判定作废。

## 验证

测试工具链为 Xcode 27.0（27A266a）、iOS 27.0 的 iPhone 18 Pro **模拟器**，设备 ID `4E3819A2-8D9A-4A38-A90F-B0E063FF07B4`。搜索对比使用相同 Debug 配置与相同生成规则的匿名数据，每项 XCTest 测量 5 次；数据准备在计时区间外。

| 搜索场景 | 优化前平均耗时 | 优化后平均耗时 | 耗时下降 |
| --- | ---: | ---: | ---: |
| 全局搜索：20,000 只羊、2,000 个圈舍，输入 `SH`，各返回前 50 项 | 463.50 ms | 15.49 ms | 96.66% |
| 表单耳号搜索：20,000 只羊，输入 `SH`，返回前 8 项 | 64.37 ms | 12.87 ms | 80.01% |

这是按耳号有序、宽泛匹配场景下的函数耗时；两次测试都断言了结果 ID、顺序与命中总数。没有把它换算为整个 App 的提速比例，也没有用主进程峰值内存推算搜索的内存节省。

| 验证项 | 结果 |
| --- | --- |
| 改动前搜索基准 | 两项执行通过；原始 xcresult 已保存 |
| 改动后完整 XCTest 与性能基准 | Xcode 结果 `Passed`：666 项，663 通过、0 失败、3 跳过；其中 8 项性能测试全部通过 |
| Web | 97/97 测试通过，构建通过，Sites 6/6 通过；无 Web 源码改动 |
| CloudBase 网关 | 语法检查通过，33/33 测试通过 |
| 遗留 Identity Worker | TypeScript 检查通过，16/16 测试通过；本地 fixture，非远端服务验收 |
| 代码静态门禁 | Emoji、本地化、98 个模型分类、历史消费者、云品牌边界、87/87 云命令、Privacy Manifest 均通过 |
| 完整发布静态门禁 | 未通过：本机缺少 Staging 公开配置；单独放行该配置检查后还发现既有发布文案占位符 |
| `git diff --check`、修改 Swift 语法解析 | 通过 |

`VERIFY_PUBLIC_CONFIG=0 VERIFY_ALLOW_LEGAL_PLACEHOLDERS=1` 的 static 诊断通过，只证明显式放行这两项后的代码检查。没有把该诊断当作正式发布门禁通过，也没有修改或补造发布主体资料。

新增测试覆盖正序、倒序、打乱输入、相等排序稳定性、精确匹配后到、零/负数/极大 limit、排除项、真实总数，以及 20,000 候选时比较次数的回归上限。没有为死界面删除编写“检查源文件字符串消失”式测试。

三项跳过仍按原测试条件执行：真实云源检查点导入、真实牧场历史修复跨重放对比、真实牧场修复快照激活。它们未被计作通过，也未为本轮验证连接生产云或导入真实牧场数据。对改动前云测试的单独复核使用 iPhone 18 Pro Max 模拟器和保留的原始测试二进制，49 项中复现相同的 9 项失败。

第一次完整运行的用例已结束，但 Xcode 在失败诊断收集阶段停滞，保存原始日志后停止了该次进程。最终修复测试夹具并以 `-collect-test-diagnostics never` 重新执行全部测试，得到完整 `final-tests.xcresult`；正式结论只引用这份完成的结果。

## 备份与证据

- 第一批源码备份：`backups/20260926-101907-skill-backup/`。
- TMR 和工作台补充备份：`backups/20260926-102526-skill-backup/`。
- 云测试 fixture 补充备份：`backups/20260926-103344-skill-backup/`。
- 日志、删除明细、剩余候选、xcresult：`/Volumes/移动硬盘/eSheepNext-Dev/CodeAudit/20260926/`。
- 优化前搜索：`search-before.xcresult`；基线失败复核：`cloud-baseline.xcresult`；最终回归：`final-tests.xcresult`、`final-test-summary.json`；5 次采样明细：`performance-metrics.json`。
- 后续构建产物：`/Volumes/移动硬盘/eSheepNext-Dev/DerivedData/code-audit-20260926/`，显式设置 `SYMROOT`、`OBJROOT` 避免本机 Xcode 全局输出设置覆盖。

本轮不变更数据模型、云写入协议、同步权威或历史恢复语义。运行时间对比仅适用于上述模拟器搜索函数，不能据此声称整机帧率、冷启动、峰值内存或全部页面已达到性能目标。真机交互性能尚未测量。修改保留在本地工作区，尚未提交或发布。
