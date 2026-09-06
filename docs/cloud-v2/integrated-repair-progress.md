# 云 V2 一体化修复实施记录

当前生产写入已恢复，Air Build 19 的原 10 条操作全部 accepted。用户要求停止测试，直接交付 TestFlight 新安装版；正在发布检查点并归档 Build 20。以下带时间的记录为历史状态，以最新交付记录为准。

## 最新有效候选与设备边界

- 22:02：tests33 最新历史暂缓维护专项通过（1 项，0 失败）。新待处理操作和手机尚未追赶到新检查点时暂缓，不误报校验损坏；实际摘要不一致仍拒绝。95 模型静态门禁与 diff 检查再次通过。此前“正在/待复测”文字为各阶段历史状态，以本条及第九候选结果为准。

- 22:00：第九次本机 Release 候选已通过（回放/导入 XCTest 248.050 秒）。H 49,344，45 片 gzip 共 9,841,153 字节；导入库逻辑 31,145,984 字节、分配 31,502,336 字节。独立 SQLite、批准历史 46 表/96,215 字段/8 条死亡及 176 条用途历史三份报告通过并绑定同一清单/来源。发布器只读校验通过，没有联网写入。清单 SHA-256 `d0e1bbd3db5334acd57ecb9e33e82807c1439d952334f5297a6f6bd9f65fcc6b`。
- 第九候选的用途历史仅需下载 1 个 187,491 字节分片，按模型索引筛出 176 条业务事实；同片其余模型不会覆盖到已激活库。这是候选字节统计，不是已在 Air 执行的结果。
- 第九候选业务格式与三项来源门禁为当前有效结果；客户端暂缓维护分支由紧接的 tests33 复测。runner 再次实时核对为 `offline`、`busy=false`；GitHub 上尚未运行该任务。

- 发布门禁复核补齐批准历史报告的强制校验，三份报告均绑定清单/来源/边界，服务端发布证明改为三份摘要的组合哈希。新增离线回归覆盖缺失、失败、清单错配、来源错配与边界错配，全部拒绝；正确候选只校验、不联网。该 Python 门禁将用于第九候选，不修改业务投影。

- tests31：56 项、0 失败、2 跳过；tests32：非零边界专项 1 项通过，均有独立 xcresult。原队列字节保护、坏分片、换账号、原版本票据续签、并发合并与重复恢复均通过。
- 第九次 Release 候选重建正在执行，包含分片模型索引；不要复用第八候选的清单用于新发布门禁。重建启动后，客户端历史维护另补“有新待处理操作/检查点边界较新则暂缓”的处理，尚待专项复测；它不改变云源回放、导出格式或候选业务字段。
- 当前静态专项再次通过：95 模型字段/归属覆盖、历史消费者扫描、本地化、diff 空白检查。隔离数据库七项检查点 RPC 与回退控制权限查询全部通过；尚未表示生产具备这些入口。

- 21:40 更新：第八次受控本机 Release worker 已通过，候选 `protected-worker-dry-run-8/candidate`：H 49,344，gzip 9,840,404 字节，导入数据库逻辑 31,248,384 字节、分配 31,502,336 字节。全量回放/导入逐字段、原 46 表与 96,215 字段、8 条死亡记录及新增用途历史独立核对全部通过。真实 HTTP 同边界降幅和 Air 数据库占用尚未验收。
- 新发现并补齐 176 条用途变更业务历史：对应 352 条双流事件的 176 个不同原命令。仅该类型 DomainOperation 纳入检查点，其他技术审计拒绝混入；离线时间线、前用途、原命令引用保留。独立云源对账已纳入构建/发布门禁。
- tests28 独占模拟器重新运行大规模云源回放通过（118.461 秒）；tests30 新用途历史、多流重复与 V2 回归共 55 项、0 失败、2 跳过。此前 tests27 SIGTERM 不是可复现业务失败，但根因尚未独立确认。
- 已实现已激活牧场的用途历史补入：分片清单增加模型索引，只下载相关分片；原队列未解决、边界链不一致或成员变更均停止。插入与小型完成证明同事务，不替换羊只/牧场，不移动游标，不删除协议回执。该实现和索引是第八候选之后的新增代码，正在 tests31 与补充边界测试验证；第八候选缺少索引，不能通过当前发布门禁，须重建。
- 检查点保留策略在隔离真实 HTTP 通过：最近两个版本及调查固定版本保留，旧版本先退役、等待超过下载票据期限后原子认领；实际 Python 维护 CLI 删除精确分片并回读确认、支持中断重试与完成确认。退役版本不能重新发布，普通客户端不能操作。没有清理生产检查点、旧快照或账本。新保留 RPC 已加入发布预检。

以下记录按此前实施阶段保留；候选、构建和测试证据仅覆盖各自生成时的源码。

- 20:05 正常签名的完整 XCTest：559 项，0 失败，2 项旧私有夹具缺失跳过。上一轮无签名全套的唯一 Keychain -34018 失败，在正常签名专项及完整重跑均通过。之后的 JSON 分片编码优化尚未纳入该全套结果。
- 回退控制已实现并在隔离后端验证：按牧场/generation 独立暂停新检查点接收和发布，新接收明确返回旧路径原因；已保存 checkpoint ID 继续按原版本续传；普通成员不能改开关，发布方不能绕过暂停内部函数。真实 HTTP 与 7 项权限 pgTAP、原 13 项检查点 pgTAP 均通过；生产未部署。
- 发布只读预检增加清单/审计/发布入口、内部绕过权限及回退控制表依赖检查；在隔离库运行全部新查询通过。
- 正在进行无损体积优化：两个同步流 JSON Data 字段使用显式结构化 JSON；无法规范编码成相同原始字节的内容保留 Base64 兼容表示。原始字节专项通过；tests27 结果为 51 通过、2 跳过、1 大规模云源回放收到 SIGTERM，随后模拟器诊断收集 600 秒超时；不能宣称该轮整体通过，也不能将 SIGTERM 直接认定为业务断言或内存错误。该轮后续独占重跑和第八候选结果见上方。

- 最新进展：用户明确指定系统鼠标后，已通过系统截图和鼠标坐标操作 Air，完成「首页 → 账号 → eSheep+ 云 → 数据与存储」现场读取。此前 Device Hub AX 超时仍存在，但不再阻塞这条鼠标通道。
- 250 MB 口径已定位：Build 18「设备存储 / 牧场资料」显示 **251.5 MB**，对应 `AppStorageUsageService` 对 Application Support 的实际分配字节统计，包含业务库、照片与接收副本；不是云端下载量。临时文件 7.5 MB、合计 259.1 MB。云页面同时显示正在保存 10 项。截图和来源说明保存在 `air-visual-evidence`。
- Air 修复前性能：系统级 Animation Hitches 记录 46.122477 秒，目标确认 Air / Build 18；主线程 6 次停顿超过 100 ms，最长 **1448.101834 ms**。停顿区间 6701 个主线程样本中 6379 个包含云同步链，主要涉及 `applyEventPage`、`preload`、`loadStreamsIfNeeded`、`loadReceiptsIfNeeded` 和 `finalizeAcceptedIntents`。这是采样中的包含关系，不能相加，也不是输入延迟 p95。基线报告与原始 trace 已保留。
- App Store Connect 已登录并现场核对：TestFlight 当前最高 Build 16，Air 本地正式包 Build 18；新构建号统一采用 **19**，项目全部 6 处版本与发布检查脚本已同步。未上传或改变测试群组。
- Build 19 首轮 Release generic-iOS 编译和内部发布脚本的 78 项回归通过；之后增加了接收任务合并、查询谓词及数据存储页说明，最终 Release 正在重新构建，不能复用早期构建作为最终归档。
- tests23/24 的 V2 回归与 tests25 接收专项通过：扩展到实际称重增量后发现新流的随机内部编号和本机创建时间导致两路径不一致，已改为首次不可变事件编号及接收时间；同检查点并发接收共用任务，账号或清单不同不能合并；磁盘不足、失效成员、待上传命令保护、账号切换、损坏分片与续传均有对应回归。
- 持久化变更历史消费者盘点为 0，现有删除入口仍只有 `LocalStorageOptimizationService`；新增检查阻止未纳入保留位置保护的历史消费者通过静态门禁。没有执行 ACHANGE 删除或数据库压缩。
- 第六次本机 Release worker 已通过：`protected-worker-dry-run-6/candidate`，H 49,344、gzip 11,270,724 字节、数据库逻辑 31,006,720 字节 / 分配 31,502,336 字节；全量回放与导入逐字段一致、46 表 / 96,215 字段 / 8 条死亡记录专项均通过。随后 Core 查询范围和存储模式兼容显示有小改动，tests26 已通过；该候选仍未发布。
- 用户确定使用当前 MacBook Air 运行检查点 CI。已创建 GitHub `esheep-cloud-checkpoints` 环境，限制 main 分支并要求仓库所有者审核；外部贡献者运行一律需要审核；6 项环境变量已设置。官方 SHA-256 校验的 2.337.0 ARM64 runner 已注册为一次性、当前离线，未安装常驻服务，未复制源读取或发布凭据，也未执行 GitHub CI。公开仓库只输出对账通过/失败摘要，详细业务证据保留本机。证据：`verification/macbook-air-ci-configuration.json`。

- 用户最新指示将实机性能和接收验收目标改回 iPhone Air（00008150-000128C93640401C）；已重新确认连接，正式包 3.1.1（18）、开发包 3.1.0（13）。发布设备门禁同步改回 Air；16 Pro 备份保留，之前的设备切换记录仅为历史过程。
- Air 重连后新增独立 `air-reconnected-container` 备份：305 文件、280,329,861 字节，3 个 store quick_check 通过。与前次备份逐条比较，10 条原命令的编号、正文、摘要、账号/设备身份引用、设备序号、命令依赖和资源依赖全部相同，无新增操作；当前均 awaitingResult，重试次数 10–12。对应清单为 `air-reconnected-backup-manifest.json` 与 `air-reconnected-queue-reconciliation.json`。仍是运行中只读复制，未导出 Keychain，不替代发布窗口停用后的最终备份。该备份时 Device Hub 返回 AX -10005；后来已通过系统鼠标取得上述 Build 18 UI 和修复前性能证据。
- `backups/cloud-v2-integrated-20260906-153230/protected-worker-dry-run-5/candidate` 已完成本机 Release worker 构建、真实云端封存源全量回放、检查点导入及两项独立对账。它尚未发布，也不是受保护 GitHub CI 的运行结果。
- 本次边界 49,344；gzip **11,339,279 字节**；数据库逻辑 **31,068,160 字节**，分配 **31,502,336 字节**；历史协议回执 0。真实网络降幅和设备占用尚未验收。
- 独立 SQLite 标量字段一致性通过；已批准历史的 46 表数量、96,215 个字段、3,264 只羊、11,180 项业务事实、8 条死亡记录通过。旧分类差异中 9,629 项保持一致，另 26 项照片定位字段仅允许按 verified 资源合约从空值确定性重建。
- 6,693 个历史 recordedAt 值来自哈希匹配的已批准修复证据；构建任务核验相应命令存在于云端事件前缀。没有将手机库作为候选来源。
- tests18 的 V2 和 schema 迁移回归通过，包含错误重复回执的命令编号校验、逐条结果保护与配置错误 900 秒重试持久化。后续接收取消/账号切换保护已补充，专项回归结果另记。
- tests19 的账号切换拒绝激活专项通过：已下载分片可复用，但新账号不能将旧账号的检查点激活到正式库；恢复原账号后可正常激活。另补充最后一次异步复制后、提交前重新检查正式库为空的保护，避免复制期间出现的待处理操作被覆盖；包含该保护的 tests20 接收/暂停/恢复/激活/维护回归通过，尚未独立模拟每一种并发写入时序。
- 候选 worker 的 Release 证据对应其构建时源码；后续接收保护仍须纳入最终签名 Release 归档验收。现已选定本地 Build 19，未上传。
- 此处覆盖下方早期候选的当前状态；早期失败候选保留作为调查证据，不可用于发布。

## 基线与恢复资料

- 源码及原未提交改动备份：`backups/cloud-v2-integrated-20260906-153230/source`，附原始 diff/status。
- Air 正式包现场为 3.1.1（18）；开发包 Build 13 保留。
- Air 容器备份附 305 个文件的哈希清单，3 个 SQLite store 的 quick_check 通过。该次为运行中只读复制，不能替代发布窗口的停用后备份；Keychain 没有导出。
- 云端 SELECT-only 封存源在该备份下 `cloud-source`，边界从源读取，本次为 49,344，未写死到生产逻辑。

## 已得到的证据

- 后台 local-store actor、空事件页捷径、按实体流查询和错误分类已编译通过。
- 旧云 V2 测试集与数据库迁移测试通过已运行的一轮回归。
- V13 → V14 专项测试保留原命令字节、编号、账户/设备引用、设备序号、依赖、12 次重试和下次重试时间。
- 95 个当前模型有明确检查点归属；静态门禁与运行时 SwiftData 字段覆盖检查相互独立。
- 检查点接收测试覆盖导入后取消、持久化暂停、复用已下载分片、按当前 worker 身份激活。
- 第一个候选的业务 DTO 摘要对账通过，但独立 SQLite 对账发现 Date 经 Unix 毫秒转换的浮点精度变化。该候选不发布。
- 第二个候选改用 Date 的 reference-epoch Double 原值；所有传输模型的 SQLite 标量字段逐项对账通过。
- 第二个候选 gzip 字节 11,352,038；导入数据库逻辑字节 31,039,488、实际分配 31,502,336；历史协议回执 0。以上是本地候选测量，不是真实网络/Air 测量，也尚未证明完整旧路径同边界降幅。

- 独立本地后端全部 SQL 测试文件通过；新增检查点授权/空清单拒绝等 13 项、原 V2 150 项通过（HTTP 测试使用独立测试数据，SQL 全套在重置的一次性数据库上运行）。
- 独立本地真实 HTTP 测试发现 Edge server role 缺少设备公钥读取权限；新迁移显式授予 device_id/user_id/public_key_jwk/status 四列读取权限。后续生产只读预检显示生产当前已具备这四列权限，不将本地权限缺失误写为已确认的生产故障。
- 真实 HTTP 已通过有效签名提交、原号重复提交不增事件、原号状态查询、两设备冲突解决、先拒绝未就绪撤销再用原命令完成顺序恢复、有效照片确认、损坏照片拒绝、错误签名/跨牧场/匿名/失效成员拒绝。结果在 verification/writes-real-http.json。
- 接收文件维护、后台页面汇总、日期原值编码与最新客户端已通过对应已运行回归；新增加的增量对账曾发现流状态 updatedAt 使用当前时间，已改为事件接收时间，检查点加增量逐字段回归已通过。
- 固定 H 的来源采集已改为单一 MVCC 语句封存可变元数据，随后分页读取不可变事件；生产后续追加不再导致任务要求最新 head 不变。

- 检查点私有 Storage 与发布接口真实 HTTP 验证通过：空清单、缺失对象拒绝、重复发布与标识不可变、固定版本票据、gzip 二进制哈希、私有直读拒绝、匿名/跨牧场/失效成员拒绝、已不存在的固定版本返回 410。该项验证传输协议，完整业务导入有独立 Swift/SQLite 证据。
- 用户将真机验收目标改为 iPhone 16 Pro（00008140-000164E22062201C）。正式包/开发包均为 3.1.1（16）；正式容器备份 162 个文件、100,867,279 字节，2 个 store quick_check 通过。正式库羊只/待上传均为 0，旧 staging 回放 546 条，尚未激活。运行中备份未导出 Keychain。
- Device Hub 按应用名和准确 Xcode 应用路径读取均返回 AX -10005；尚无真机 UI 或性能通过证据。

- 第三个候选：压缩 11,351,176 字节，导入 store 逻辑 31,047,680、分配 31,502,336；独立逐字段对账通过。另与已批准来源核对 3,264 只羊、11,180 项业务事实、96,215 个字段以及 8 条死亡记录通过。该历史专项不替代完整 46 表的旧例外分类复核。
- tests13：53 项中 51 通过，2 项旧私有夹具缺失而跳过；tests14 损坏分片、固定版本过期票据恢复、暂停续传通过；tests16 逐条结果保护与 900 秒重试持久化通过。
- Release 无签名 generic-iOS 首次优化构建通过；之后又修改了队列保护和描述字段不触发占栏历史重算，最终 Release 仍须重建。
- 生产只读发布预检：Release Build 18 指向预期项目；两项函数均缺失/404，四项底层 RPC server execute/client denied 通过。预检按预期不通过，未部署。
- 完整 static 入口当前未通过：缺少 StagingEnvironment.local.xcconfig。此前 static2 是 CI 配置缺失跳过与预发布占位符允许模式，不能称作完整发布静态门禁通过；本轮模型覆盖、本地化、品牌边界、83/83 命令覆盖与隐私清单语法检查已通过。
- 完整 Release 检查点 worker 首次试跑因 Release 未启用 @testable 编译失败，已将 ENABLE_TESTABILITY=YES 限定到构建任务，正在重跑。
- App Store Connect 当前未登录；下一可用构建号尚未核对、未修改。

- 完整 Release worker 第二次试跑已经连续通过构建、实际 XCTest 运行、全量回放/检查点导入以及独立 SQLite 对账；它不含随后发现的历史元数据修复，不能发布。
- 进一步核对旧 46 表例外时发现：6,693 个 Weight/Removal/Weaning.recordedAt 原先使用回放时钟，另有 1 个已确认原图的 PhotoAsset.cloudRecordName 未从资源状态重建。第三候选只证明基准和导入一致，完整历史例外核对未通过。
- 正在修复：构建任务接入已封存、哈希匹配的批准记录，仅恢复三个明确的 recordedAt 字段，并验证该批准的 14,477 个命令均存在于同牧场/generation 的云端事件前缀；新事实投影使用不可变云端接收时间。已验证原图名称按现有 Storage 合约重建。Release worker 第三次试跑正在执行，结果未定。

- 源码 tests17 的 V2/迁移回归通过；原照片路径拼接中的可选摘要已显式解包。生产只读核查确认 27 个 verified 原图都存在 Storage 对象，27 个路径及对象大小均匹配。旧照片记录的空云端定位字段与完整已验证资源引用属于不同缓存状态，独立对账仅允许严格匹配已验证资源合约的派生定位字段，不放宽业务关联字段。
- GitHub 只读检查：当前仓库没有自托管 runner、没有检查点保护环境、没有 Actions variables；受保护 CI 尚未实际配置或执行。当前通过/运行的 worker 证据均来自本机受控试跑。

## 当前尚待完成的门禁

- 新增后台汇总、维护路径、诊断指标及最新客户端修改的完整回归。
- 缺损/跨账户/过期票据/解压上限/磁盘不足/激活中断的接收故障矩阵。
- 受保护的检查点构建/发布任务、增量期间固定边界构建、上线入口与依赖检查。
- 日常自动构建的历史验收目前对旧批准事实采用严格比较；未来合法新增/修改会阻止候选发布，需要补齐基于批准边界加后续事件的历史验收，不能静默放宽条件。
- 既有已激活库协议回执精简、历史消费者保留位置验证，以及 Air 旧接收目录的明确备份/清理证据。
- 同边界旧路径下载比较，全部已批准历史特殊情况的独立来源对账。
- iPhone Air Release 性能和接收/恢复验收；Air 原始队列须以原设备身份逐条核对恢复；统一受控发布、仅 3.1 Internal 分发和发布后 24 小时观察。

完成状态必须以逐项门禁证据为准，不能将编译/模拟器测试或候选尺寸达标当作最终交付。

## 2026-09-06 22:32 Air Build 19 physical acceptance update

Air formal bundle was backed up quiescently and updated in place to 3.1.1 (19), Release optimized, using an Air-authorized development signing profile. Build 13 was preserved. Existing account and farm opened successfully. Production writes/checkpoints remain unavailable; no backend deployment or TestFlight distribution occurred. Cleanup was disabled at launch.

Real UI exercised account, cloud status/manual check, cloud and home scrolling, ear search A058, selection and unsaved weighing keyboard input. Draft was cancelled. Original 10 commands retain byte-exact IDs, envelopes, digests, identity and dependencies; all remain awaitingResult. Before/after SQLite quick_check passed. Business table counts unchanged (only Core Data bookkeeping/history counts changed). Evidence: verification/air-build19-after-ui-queue.json.

601-second Activity Monitor + Hangs recording for formal PID 29959 reports five main-thread delays above 100 ms: 137.535, 113.526, 196.012, 294.582, 142.962 ms. Attribution is unresolved: this recording has no sampled stacks. Performance gate remains OPEN, input feedback p95 unmeasured. Physical footprint peaks at 146.31 MB, final 63.49 MB; last three minute averages approximately 63.5 MB. Threads peak 11 and end 7; no sustained growth observed in this run, not a leak-proof result. Build 18 had a different 46-second instrument/workload, so do not calculate an apples-to-apples improvement percentage.

Cloud UI separates business/sync 55.5 MB (allocated 56.6 MB), reconstructible receive files 186.7 MB (187.4 MB allocated), photos 5.1 MB (5.2 MB allocated). Air size gate remains OPEN; candidate size is not Air size. No receive/history data was deleted. Detailed evidence under backups/cloud-v2-integrated-20260906-153230/air-visual-evidence/build19-ten-minute-summary.json and trace.

Physical post-install field comparison: all common business fields match by table, primary key and column name. Core Data Z_ENT entity numbering changed during schema migration; Z_OPT changed on farm bookkeeping. Pending-intent transport retry metadata and membership updatedAt changed as expected. Do not interpret raw SELECT * inequality as business-data corruption. Detailed column changes: verification/air-build19-field-comparison.json.

Follow-up 45-second Animation Hitches cloud navigation/scroll capture: formal PID 29959 had one 90.153 ms delay and zero above 100 ms. 88 sampled main-thread stacks overlap the 90 ms interval; system symbols are mostly unresolved, with UIKit/SwiftUI/AttributeGraph frames present. This short run does not reproduce or explain the five earlier >100 ms delays, and does not close the performance gate. Raw trace and exported profile retained. System mouse released back to user after UI operations.

## 2026-09-06 22:42 Production upload restored

User explicitly superseded the unified test-before-write gate and directed immediate production upload restoration. Deployed existing esheep-cloud-v2-writes integrated-v1 to Release project rnqrvthbunrzqtprquqx, keeping its in-function getUser authentication, device signature validation and service-only RPC permissions. No test suite rerun, no business SQL rewrite. Anonymous HTTP now returns 401 with service version instead of 404.

Triggered Air manual save check. All ten original command IDs returned accepted from production esheep_cloud.commands; event sequence advanced from 49344 to 49359 (15 protocol events for ten original commands). Air Build 19 visibly shows green 已安全保存, no waiting operations and no attention items. Screenshot air-visual-evidence/build19-production-upload-saved.png. Formal Build 19 already installed; no reinstall or identity replacement needed. Production checkpoint service and size maintenance remain separate unfinished work; do not describe all integrated objectives as complete.

## 2026-09-06 TestFlight Build 20 owner-directed delivery

User explicitly requires no tests this turn and personally owns acceptance. No automated tests or physical performance sampling run. Production checkpoint migrations and esheep-cloud-checkpoints function deployed. Candidate 9 checkpoint 4ba3cbec-f4c4-48f2-9c5e-de4dcf953318 activated at H 49344 with 45 immutable shards / 9,841,153 gzip bytes. Later accepted operations remain in the event tail; no ledger rewrite. Existing candidate proof retained; publication uses explicit owner-release-without-new-tests switch, never fabricates physical test results.

Build number advanced to 20 in all project configurations and maintained release script default. Original modified files backed up under backups/cloud-v2-testflight20-20260906. Archive building. New install from TestFlight requested; temporary Build 19 container cleanup is not a separate task. User acceptance checklist: docs/cloud-v2/build20-user-checklist.md.
