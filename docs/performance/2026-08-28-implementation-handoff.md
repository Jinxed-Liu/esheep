# eSheepNext 性能分期优化实施交付清单

## 结论

本轮已在 `codex/performance-staged` 上完成可由当前本地环境安全证明的低风险批次，
没有整体重写，没有改变业务写入入口、`DomainOperation`/Outbox 格式、备份格式、
Supabase 表或 RLS，也没有部署、上传 TestFlight、迁移生产数据或清理输出目录。

当前可以确认：高频图片不再在 SwiftUI `body` 中同步重复解码；Root 的后台任务具备
single-flight、取消、上下文 lease 和通知合并；Web 首屏与路由代码已分包，工作区改为
按页面补载并拒绝旧牧场响应；完整 XCTest 已恢复；离线性能回归目标、组合验证脚本、
CI 数据库临时环境和后端兼容边界已经建立。

当前不能确认：真实 iPhone 上的 P95、hitch、冷启动和峰值内存是否达到目标；稳定
Xcode 的签名 Archive/TestFlight 是否通过；本地一次性 Supabase 的 pgTAP、lint、
advisor 和真实查询计划是否通过。以下未完成项不是以编译结果替代验收，而是明确保留
为下一批的外部或证据门禁。

## 已完成

### 阶段 0：保护、职责和基线

- 在 `codex/performance-baseline-20260827` 建立本地安全提交 `80059b6`，保存优化前
  22 个已跟踪 WIP，以及 `InsightSkills/`、`InsightFarmQueryEngine.swift` 两组代码
  内容；`outputs/` 未纳入、未删除。
- 从安全提交建立 `codex/performance-staged`，所有性能改动按主题独立提交。
- 更新 3.1 存储职责说明和 README 边界，锁定 SwiftData 投影、
  `FarmCommandService`、Outbox、Supabase、CloudBase、CloudKit 迁移路径和遗留
  Identity Worker 的职责。
- 新增基于 `OSSignposter` 的 `PerformanceTrace`。Debug 默认启用，Internal 构建需
  显式启动参数启用；字段只接受操作分类、数量、耗时和匿名 revision。
- 保存 Web、XCTest 和离线性能诊断报告；没有伪造尚未取得的真机指标。

### 阶段 1：iOS 高频路径

- 新增 `AppLifecycleCoordinator`，Root 的认证恢复、同步唤醒、迁移恢复、Insight、
  头像和维护任务按上下文管理；相同任务 single-flight，牧场/账户/authority 上下文
  改变会取消旧任务并使旧 lease 失效，业务通知以 150 ms 窗口合并。
- 新增 ImageIO 后台缩略图管线，缓存键为内容摘要、目标像素和 scale，内存缓存有界，
  支持任务取消、内存警告、退出、删除和摘要变化失效；账户头像与 Insight 高频附件
  已迁移。
- `IdentityWorkerClient` 已用 `EmptyResponse` 的类型安全请求路径替代强制类型转换；
  空响应、非空响应、错误 body、取消、401/403 和解码失败有回归覆盖。
- 未对约 204 个 `@Query` 做机械替换。Root 的 8 个根查询经静态核对主要是账户、
  牧场和权限低基数集合；在没有 Instruments fetch 证据前保留其历史与观察语义。
- 未增加 SwiftData 索引。当前没有 10 倍数据下的真实 fetch plan 证明，避免为行数目标
  引入无依据 schema migration。

### 阶段 2：Web 首屏、路由和装载

- 7 个功能页拆成独立路由模块，移除单个 `FeaturePages` 全功能 chunk；Supabase
  客户端延迟到会话恢复阶段，认证恢复期间保持明确 loading 壳层。
- 初始三个 JavaScript chunk 合计约 93.22 KB gzip，较审计值 162.68 KB 下降约
  42.7%，低于 130 KB 门槛；Vite 转换模块从审计时 4,627 降为 153。
- 新增 `WorkspaceDataSource`：`loadOverview`、`loadHerd`、`loadRecords`、
  `loadTMR`、`loadInsight`、`loadForPage` 和 `invalidate`。
- 请求绑定 farm、authority generation 和 request generation；相同请求 single-flight，
  新请求用 AbortSignal 中止旧请求，即使底层忽略取消也会丢弃迟到响应；缓存按
  farm、authority 和 revision 分区。
- 概览继续读取当前状态与历史正确性必需的 farm、pen、sheep、feed、transfer、
  removal、operations 和 compact checkpoint；weight 与三类 TMR 实体延迟到对应
  页面。没有为了减少请求破坏历史归档、删除/恢复或迁移基线语义。
- 圈舍计数和实体去重改为单遍 `Map`；纯 Web fixture 覆盖稀疏 payload 合并、旧字段
  保留、ID 标准化、单遍计数和稳定去重。
- 没有增加 `workspace_overview_v1` RPC：当前本地包体门槛已达标，但尚无 Staging
  真实网络证据证明概览 ready P95 高于 1 秒，条件触发门槛未成立。

### 阶段 3：后端边界、验证和 CI

- CloudBase 协作入口先抽出存储适配器，原 endpoint、状态码和 JSON shape 不变；
  现有 33 项契约测试保持通过。
- 建立遗留 Identity Worker 的调用方、路由、配置和发布环境矩阵；仍有客户端引用，
  因此没有删除路由或停止测试构建。
- 未启用 CloudKit 的运行路径改为延迟创建 CloudKit runtime，修复测试宿主在任何
  XCTest 执行前由 `CKContainer` 初始化触发的 iOS 27 beta 崩溃；真实 CloudKit
  操作仍使用原容器、数据库、同步引擎和 authority 路径。
- `tools/verify_local.sh` 拆为 `static`、`ios`、`web`、`backend`、`db`、`all`；
  `all` 保持正式总门禁。GitHub Actions 已加入静态、Web、后端和一次性 Supabase
  migration/pgTAP 门禁，且不含部署、生产迁移、上传或输出目录清理动作。
- 新增独立、非并行 `eSheepNextPerformanceTests` 目标，使用内存 SwiftData 和匿名
  JPEG fixture，不访问任何生产云。

## 验证结果

| 门禁 | 当前结果 | 证据边界 |
| --- | --- | --- |
| 完整 iOS scheme | 601 项发现，600 项通过，0 失败，1 项按现有 iOS 27 beta CloudKit 保护逻辑跳过 | xcresult 为 Passed，0 runtime warning；不是稳定 Xcode 发布证据 |
| 离线性能目标 | 6/6 通过 | 20,000 耳号搜索 7.81 ms；首页 41.41 ms；Care 16.61 ms；投喂 41.62 ms；历史 42.12 ms；图片 3.12 ms，均为 beta 模拟器中位数 |
| Web | Node 14/14，Sites 4/4，生产构建通过 | 初始 JS 93.22 KB gzip、153 模块、npm audit 0；本地演示模式，不代表真实 Supabase 网络 |
| CloudBase 网关 | 33/33 通过 | 本地协议回归，不代表已部署 |
| 遗留 Worker | 16/16 通过 | TypeScript 与本地协议回归，npm audit 0；不代表远端 secrets/环境 |
| Debug iOS 构建 | 通过 | 通用模拟器；只证明可编译与测试宿主可运行 |
| Release iOS 构建 | 通过 | Xcode 27 beta、通用真机、无签名；不替代 Archive/TestFlight |
| 静态子门禁 | 代码、本地化、两个 Privacy Manifest 通过 | 完整 static 被缺失的本地 Staging 公开配置和并行法务占位符阻塞 |
| `git diff --check` | 通过 | 性能提交无空白错误；工作区仍有明确排除的并行法务 WIP |

离线性能用例的规模、等价性断言和采样方式见
`docs/performance/2026-08-28-xctest-performance.md`。Web 请求矩阵、浏览器检查和限制见
`docs/performance/2026-08-28-web-route-loading.md`。

## 未完成及继续条件

1. **稳定 Xcode 与发布链**：用项目认可的稳定 Xcode 重跑完整 XCTest，要求 0 失败、
   0 跳过，再执行签名 Archive 和内部 TestFlight；beta 结果不得升级为正式门禁。
2. **真实设备性能**：固定同一台 iPhone、Release 配置和同一牧场数据，冷启动 10 次、
   高频交互至少 30 次，采集 SwiftUI、Time Profiler、Hangs、Animation Hitches、
   Allocations 和内存曲线，才可判断 20% P95 与内存目标。
3. **XCUITest smoke**：当前 App 没有确定性的离线 UI 启动 fixture，正常启动依赖安全
   账户、法律同意、本地 SwiftData 与后台云任务；并行法务 WIP 正在改变同意门禁。
   待该 WIP 合入后先增加隔离 UI fixture，再覆盖启动、选牧场、羊群、搜索、Care、
   TMR、历史、图片和前后台切换，不能以当前用户数据录制脆弱点击脚本。
4. **同一跨端投影 fixture**：Web 已有纯辅助 fixture，Swift 已用真实服务分别覆盖
   历史、恢复、TMR 反转、authority 和 checkpoint，但两端尚未消费同一物理 fixture。
   Web 当前也未投影 TMR 批次/反转。下一批应先抽取两端真实投影入口，再让同一
   fixture 驱动它们；不能用测试专用重复算法伪造一致性。
5. **Supabase 数据库**：在隔离的一次性本地实例或 CI 数据库执行 migration、全部
   pgTAP、lint、security/performance advisor，并在当前与 10 倍匿名数据上保存
   `EXPLAIN (ANALYZE, BUFFERS)`。本轮没有触碰已被其他项目占用的本地实例，也没有
   reset 生产数据库。
6. **Root 快照、查询与索引**：等待真机 signpost 和 Core Data fetch 证据。仅当根摘要
   长期扫描被证明为热点时，才接入 `RootWorkspaceSnapshotProviding`；完整历史语义
   查询继续保留。索引必须是独立 schema migration。
7. **后端和超大文件继续拆分**：CloudBase 只完成第一块存储适配器抽取；
   `FarmCommandService`、`FarmPersistenceActor`、`CloudSyncActor` 仅在 clean 与
   incremental build 数据证明收益后，按现有 façade/actor 边界分批拆 extension。
8. **Staging Web 验收**：使用隔离真实账号复验首屏请求、快速牧场切换、401/403、
   离线、重试、内存和概览 P95；本地浏览器移动截图存在视口缩放异常，未计为移动
   视觉验收。

## 风险与保护措施

- 当前工作区存在并行法律、隐私和合规 WIP，包含 `RootView`、账户设置、Privacy
  Manifest、发布站点和数据库 migration。它们没有进入任何性能提交，交付或回退时
  必须继续按路径排除。
- Root 生命周期批次与并行 `RootView` WIP 位于同一文件的不同 hunk；不要对整个文件
  checkout、reset 或覆盖。
- Web 概览仍装载历史/检查点相关基础数据，这是正确性保护，不应把“请求数更少”当作
  删除这些读取的理由。
- 模拟器数值只适合代码回退对比；不能据此宣称真机无卡顿、峰值内存下降 20% 或
  冷启动达标。
- 未经 Staging 证据不增加读 RPC；未经查询计划不增加索引；未经兼容矩阵清零不删除
  Worker/CloudKit 迁移路径。

## 基线和可回退提交

| 提交 | 独立主题 |
| --- | --- |
| `80059b6` | 优化前 WIP 安全基线 |
| `f523b45` | signpost、图片管线、Identity transport 安全 |
| `bde9940` | 3.1 权威职责与基线文档 |
| `4da387d` | Web 静态壳、路由分包、取消和纯投影 fixture |
| `08dc828` | Root 生命周期 single-flight、取消和通知合并 |
| `f895d20` | 六类本地验证入口与 CI |
| `68d2c69` | 遗留身份兼容矩阵 |
| `e21d3be` | CloudBase 存储适配器拆分 |
| `42abf75` | 未启用 CloudKit runtime 延迟创建 |
| `280072d` | 恢复后的完整 XCTest 记录 |
| `d851c6c` | Web 按路由数据装载与 revision 缓存 |
| `8be702e` | Web 路由装载验证报告 |
| `a58f28c` | 独立离线 iOS 性能测试目标 |
| `21fa0a0` | 离线性能基线报告 |

优化前远端跟踪分支位置为 `codex/3.1-release` 的 `64ed2b4`；可恢复的本地 WIP
基线为 `codex/performance-baseline-20260827` 的 `80059b6`。任何回退都应从独立
提交逐批 revert，并先确认并行法务 hunk；不得使用 destructive reset。`output/` 和
`outputs/` 全程保持原样。
