# eSheep+ 云 V2 本机验证状态

更新时间：2026-09-04

这份记录按源数据、远端账本、设备备份、服务端测试和现场验收分层记录。2026-09-04 已按 iPhone Air 的实时备份执行真实牧场 V1 → V2 影子迁移并完成服务端验证；这不等同于 authority generation 已切换，也不把模拟器或 Device Hub 失败写成现场验收通过。

## 2026-09-03 本机基线与准备记录（历史快照）

- 已创建计划指定的 `codex/esheep-cloud-v2-cutover-rc` 分支。执行前将当前工作树（排除 `.git`、依赖和可重建产物）备份到 `/tmp/esheep-v2-source-backup.QdMDx0`，并用 `rsync` dry-run 校验无差异。
- 两台指定真机的 `com.sheepfarm.next.dev` 完整 App container 已只读复制到 `/tmp/esheep-v2-device-backups-20260903`：iPhone Air 约 89 MB，iPhone 16 Pro 约 58 MB。两份 store 均以 WAL 兼容方式执行 `PRAGMA quick_check`，结果为 `ok`；未安装、卸载或清空任何设备内容。
- 备份副本显示同一真实牧场的当前 V1 基线仍未收敛：iPhone Air 为 generation 1、已拉取到 revision 2061、3271 只羊、32 张照片、2149 条本地操作和 705 条已确认 Outbox；iPhone 16 Pro 为 generation 1、已拉取到 revision 856、3082 只羊、15 张照片、946 条本地操作和 0 条 Outbox。该差异直接阻断双机 staging，不能用其中一台覆盖另一台。
- `devicectl` 只读安装清单确认：两台设备的开发包均为 `3.1.0`，iPhone Air 为 Bundle Version 13，iPhone 16 Pro 为 Bundle Version 5；本次没有安装新的 Build 14，因为构建号上限尚未完成 App Store Connect 复核。
- 当前自动门禁新证据：静态门禁（本地显式允许法律占位符）通过，V2 静态覆盖 `80/80`；本地 Colima/Supabase pgTAP 为 9 个文件、`planned=262, todo=1, failed=0`；Debug 全量 XCTest 为应用 `539/539`、性能 `6/6`，均为 0 failures。对应日志分别为 `/tmp/esheep-v2-current-static-20260903.log`、`/tmp/esheep-v2-current-db-20260903.log` 和 `/tmp/esheep-v2-current-debug-tests-20260903.log`。
- Web 锁文件已升级 Browserslist 相关传递依赖（未改 `package.json`）；复跑后主测试 `50/50`、Sites 测试 `6/6`、`npm audit` 均通过且报告 `0 vulnerabilities`。对应日志为 `/tmp/esheep-v2-current-web-after-audit-fix-20260903.log`。Backend 锁文件也完成 `qs` 传递依赖修复；复跑测试 `33/33`，安全审计为 `0 vulnerabilities`，对应日志为 `/tmp/esheep-v2-current-backend-after-audit-fix-20260903.log`。
- 三配置 iOS 门禁没有完成：Debug 构建成功后，Staging 构建设置解析因缺少 `Config/StagingEnvironment.local.xcconfig` 停止。不会把 Release/Development 的远端配置复制成 Staging 配置。
- 远端只读检查显示当前组织没有独立 Staging Supabase 项目；已关联的 Development 项目尚未应用 V2 migration `20260902041541`，也没有部署 `esheep-cloud-v2-writes`。因此本次没有执行远端 push、函数部署、验收牧场写入或真实牧场切换。
- `use-device-hub` 的 Device Hub 读取连续因 AX `-10005 timeoutReached` 失败；没有改用 iPhone Mirroring，也没有把 `devicectl` 清单当作视觉验收证据。

截至 2026-09-03，本机准备阶段安全停在“本机准备与证据收集”边界；以上文字保留为当日快照。2026-09-04 的真实 Air 影子迁移记录如下。专用验收牧场、双机现场 staging 和 authority generation 切换仍不由本机自动化结果替代。

## 2026-09-04 Air 真实牧场影子迁移与服务端测试

- 数据源固定为 iPhone Air 的只读完整 container 备份 `/tmp/esheep-v2-device-backups-20260903/air`，store SHA-256 为 `76c813cd03774a49b98053a55d0341203e93a19fa09af1d224ea454a4093c1af`；iPhone 16 Pro 的旧 Build 5 没有参与数据源判断、命令生成或迁移覆盖。Air store 的 WAL 兼容 `PRAGMA quick_check` 为 `ok`。
- 远端 V1 恢复备份已保留在 `/tmp/esheep-v2-remote-backup-20260903`：`v1-data.sql` SHA-256 为 `a0d18f2bbe7ebf74c563a7f9974f10c6261e6d140575addbf5aa19715e61e9c8`，`v1-schema.sql` SHA-256 为 `9b478e4fd797f47ce7ede933f70ae5d2f85ab51612131e47f9c95d0c6aacb53a`。
- 目标为已登记的真实 Development Supabase 项目 `rnqrvthbunrzqtprquqx`、牧场 `8b0fa55e-2a34-4398-ae77-7d7d3701c5dd`。V2 schema 加法迁移以及真实数据探针发现的四个合同兼容修复已部署；V1 表未被重写。
- Air 提取计划 `/tmp/esheep-v2-real-migration-20260904/migration-plan.json` 的 source manifest digest 为 `8392bfd4317a61b290364698767f44281a28410ce7cb15cd2b4fc2e0c23f3201`。实际写入目标 generation 2 的命令为 `23,365` 条，设备序号连续 `1–23,365`，全部 `accepted`，无 `needs_confirmation`、无 `rejected`；共生成 `34,382` 个事件，事件 head 为 `34,382`，无命令/事件/摘要重复。新增头像修复的 5 条命令均为 `sheepAvatar.set`，直接把 Air 的新照片资产恢复到对应羊只关系。
- Air 当前 27 个活动照片资产的原图、缩略图和头像共 81 个对象已上传并逐对象服务端确认；V2 资产表为 `27/27` fully verified，原图字节数合计 `18,055,559`。新增 5 条头像关系修复后，V2 快照为 `aefb829f-de5d-46a8-90f6-ed9f7f844a50`，边界事件 `34,382`，126 个分块，`71,992,257` 字节，总摘要 `afb50ab7bf7be986b1e92a538ba60d8b20e95f081589a1ef69a3b205725c08fb`；投影摘要为 `428065740e35d058356818246360fcd629a655e082ed6fd677e0a07e0138077a`。
- Storage 侧的 `esheep-cloud-assets` 桶精确存在 81 个 generation 2 对象，metadata 字节数合计 `27,329,867`；旧 V1 `farm-assets` 桶仍为该牧场 28 个对象、`18,569,570` 字节，未与 V2 对象混用。
- 真实远端测试已完成：完整性审计通过且全部 13 类检查为 0 mismatch；`openInitialSync` 返回同一快照；事件拉取首段返回 `1–500`，尾段返回 `33,383–34,382` 且 `has_more=false`；重复发送最后一条新增头像命令返回 `duplicate`，event head 仍为 `34,382`；状态查询无 open attention。V2 当前共有 `18` 条 `sheepAvatar` 流，5 个新增头像处理项均已闭合，不需要人工选择旧头像。
- 测试完成后 V2 `farm_state` 已设为 `read_only`，migration reconciliation 保持 `shadowing`；未调用 `mark_migration_ready_v2` 或 cutover。V1 registry 仍为 `provider=supabase`、authority generation `1`、current revision `2061`。迁移报告已将服务端通过项和未完成项写入远端 `parity_report`，不是把未做的设备验收标成通过。
- 最终 V1 核对仍为：`farm_operations=2061`、`farm_entities=22967`、`farm_tombstones=234`、`farm_assets=27`、目标牧场 member rows `3`；registry 仍为 `supabase / generation 1 / revision 2061`。V1 备份、本机 Air 备份和设备 container 均未删除。
- `DH054`、`256`、`172545`、`8062`、`A058` 在 Air 当前 `ZSHEEPAVATARRECORD` 中均没有旧头像记录，但各自都有一张 Air 新增的活动照片资产和对应 `addPhoto` 原始操作。五条 `sheepAvatar.set` 修复命令已接受并纳入上述快照；V2 当前 `sheepAvatar` 流为 `18` 条、`attention_items` 为 `0`，这五项不再是人工决策门。定点检查到的唯一 Air `resolveConflict` 记录是既有开发用笔栏冲突，V1 远端也没有这五个头像的冲突载荷。
- 历史归档行共 `467` 条：其中 `460` 条未删除行已由现有 `sheep.add` 事实代表，另有 `7` 条已删除的旧 `.jpg` 遗留照片行没有业务 `sheep.add`；归档标记在新鲜设备投影中的完整语义对账仍未完成，因此不能把这部分写成 fresh-device parity 已通过。


## 已完成的可自动验证部分

- V2 命令覆盖脚本从目录、强类型载荷、命令工厂、事件 reducer、迁移映射、核心同步器和测试清单生成覆盖矩阵；当前报告为 `80/80 complete`，`0 incomplete`。
- 覆盖门禁已移除批量 `handler_schema_version = 1` / `client_projection_schema_version = 1` 的伪标记：服务端 readiness 现在调用显式分发探针，客户端 readiness 调用显式投影路由；未来重新加入批量标记会被静态脚本直接拒绝。
- V2 命令信封不包含 `baseRevision` 或 `base_revision`；字段修改使用字段观察版本、基础值摘要和设备序号。
- 本地 SwiftData V12 账本包含牧场状态、资料流、不可变意图、事件回执、处理项、资源状态、首次接收会话和迁移状态；本地业务写入与意图入队在同一个保存边界内完成。
- 首次接收使用独立 staging store。分块、摘要、记录数量、事件边界、关联和索引都必须通过才会激活；完整性/结构错误会记为失败并不触碰活动牧场，取消或网络传输错误会记为暂停，保留已验证断点供下次继续。
- 首次接收对没有历史事件的空资料流执行严格物化：只有版本为 0、字段为空且摘要确实对应空状态时才允许激活；非空缺失资料流会失败关闭。
- 资源传输不会被当作业务事件忽略：未完成资源使状态保持“正在保存”，失败资源显示“部分内容尚未保存，请稍后再试”，并且不会阻止无关业务事件继续收敛。
- 资源上传按当前牧场 generation 过滤，旧 generation 的资源不会在权威切换后继续上传。
- 服务端命令入口补充了跨账号/跨牧场/跨 generation 前置命令隔离、拒绝结果携带原始 command ID，以及处理项 resolution 的全局 command ID 摘要冲突保护。
- 同一个 command ID 现在同时绑定牧场、generation、来源请求、bundle、账号、设备、设备序号、协议/载荷版本和命令类型；任何范围或内容不一致都会拒绝，不会把另一台设备的结果当成重复成功。
- 事件回放会校验事件来源的牧场、generation、账号、设备和命令摘要后才落本地投影；首次接收激活前也会扫描活动 store 中的牧场业务数据，避免把隐藏的旧资料和新快照混成一座牧场。
- 一个命令涉及多个业务流时，服务端在同一事务内按连续事件序号为每条受影响流写入事件；客户端按命令 ID 只执行一次业务 reducer，后续事件只推进对应流，避免转群、离场、配方成员和库存语义流出现半套状态。
- 云端权威切换现在明确拒绝已经属于 eSheep+ 云的牧场、来源或目标 generation 不匹配、非 preparing/read-only 状态、未通过 parity 证明、缺少已验证快照或快照 manifest 不一致的请求；这些检查在锁定的事务内完成，未执行真实牧场切换。
- V1 迁移发现只有旧操作没有 Outbox 发送证据时，转为“前向修复”并阻断切换，不再把“没有记录”伪装成已接受回执；新增回归覆盖该状态。
- 首次接收的验证 store 使用受限生命周期，在复制到活动 store 或失败清理前释放 SQLite 容器，避免 WAL/SHM 文件仍被打开时被删除。
- 事件恢复会完整恢复照片的缩略图、头像尺寸和原图状态；缺少资源账本时对照片删除/恢复失败关闭，不会产生半套资源状态。
- 服务端语义边界已进一步收紧：字段观察、字段值类型、照护/TMR 主流类型、删除/恢复目标以及照片回收/恢复前置条件均在事务入口失败关闭；头像仍被引用的资源不能进入回收期。该门禁验证的是协议合同和事务安全，不等同于 80 种业务在真实牧场逐项执行。
- V2 牧场在前台、后台和恢复入口均不再落入旧兼容恢复页；旧 `.supabase` 牧场只进入只读迁移准备入口，旧同步器、旧 Realtime 和旧冲突中心不再作为这类牧场的正常保存路径。界面入口统一呈现为“eSheep+ 云”。

覆盖矩阵的边界：`80/80` 表示目录、强类型解码、客户端工厂/回放、迁移路径和自动化覆盖均已接线并通过静态门禁；服务端目前仍由统一 V2 事务入口按目录和合并模式承载，不能把这项静态计数误写成 80 个业务种类都已在真实牧场逐项现场执行。真实牧场影子迁移、数据对账和 authority 切换仍保持发布阻断，等待单独授权与现场条件。

## 已留存的本机门禁证据

以下日志位于本机 `/tmp`，没有上传到远端：

| 门禁 | 结果 | 说明 |
| --- | --- | --- |
| `/tmp/esheep-v2-static-multistream-final.log` | 通过 | 多流事件修复后的品牌边界、本地化、Privacy Manifest、80/80 覆盖和 diff 检查通过；法律占位项仍按发布门禁要求保留。 |
| `/tmp/esheep-v2-ios-final5.log` | 通过 | Debug/Staging/Release 构建成功；XCTest `discovered=533, failed=0, skipped=0`。 |
| `/tmp/esheep-v2-ios-after-assets.log` | 通过 | 资源状态保护后的完整 iOS 门禁；XCTest `discovered=535, failed=0, skipped=0`。 |
| `/tmp/esheep-v2-ios-final6.log` | 通过 | 最新 Root 路由、事件恢复和空资料流激活修复后的三配置构建与 XCTest；`discovered=538, failed=0, skipped=0`。 |
| `/tmp/esheep-v2-ios-final-hardening2.log` | 通过 | 最新命令范围绑定、事件来源校验和首次接收活动资料保护后的 Debug/Staging/Release 构建与完整 XCTest；`discovered=538, failed=0, skipped=0`，`failed=0`，`skipped=0`。 |
| `/tmp/esheep-v2-focused-after-guard.log` | 通过 | 针对 V2 账本、首次接收、资源恢复、迁移和页面路由的聚焦回归；测试套件通过。 |
| `/tmp/esheep-v2-db-final5.log` | 通过 | 最新 SQL 后重跑本机 Colima：9 个 pgTAP 文件、`planned=246, todo=1, failed=0`；schema lint 无错误、advisors 无问题。lint 仍提示 3 条历史函数的 volatility warning，未伪装成零 warning。 |
| `/tmp/esheep-v2-hardening-focused-20260903-3.xcresult` | 通过 | 最新首次接收保护、命令范围绑定和事件来源校验后的 V2 聚焦 XCTest：`Executed 30 tests, with 0 failures`。 |
| `/tmp/esheep-v2-db-multistream-20260903-rerun.log` | 通过 | 多流原子事件事务、命令幂等和完整性门禁重跑；9 个 pgTAP 文件、`planned=250, todo=1, failed=0`；仅保留既有 lint advisory，advisors 无问题。 |
| `/tmp/esheep-v2-multistream-focused2.log` | 通过 | 多流业务事件客户端回放聚焦 XCTest；`Executed 31 tests, with 0 failures`，包含同一命令只落一次业务事实的回归。 |
| `/tmp/esheep-v2-cutover-hardening-static-allow.log` | 通过（本地占位符模式） | 最新静态门禁：80/80 命令覆盖、品牌边界、本地化、Privacy Manifest 和 diff 检查通过；法律占位符只因 `VERIFY_ALLOW_LEGAL_PLACEHOLDERS=1` 暂放行，正式发布仍阻断。 |
| `/tmp/esheep-v2-cutover-hardening-db6.log` | 通过 | 切换前置条件、已验证快照和多流事务合并后的本地数据库门禁；9 个 pgTAP 文件、`planned=252, todo=1, failed=0`，advisors 无问题，仍有 3 条既有 volatility advisory。 |
| `/tmp/esheep-v2-migration-hardening-focused-20260903.log` | 通过 | 迁移缺少旧发送记录时前向修复、切换安全校验和多流回放的聚焦 XCTest；`Executed 32 tests, with 0 failures`。 |
| `/tmp/esheep-v2-staging-lifecycle-focused-20260903.log` | 通过 | 验证 store 生命周期收紧后的最终 V2 聚焦 XCTest；`Executed 32 tests, with 0 failures`，首次接收相关测试不再出现 SQLite WAL/SHM 占用清理警告。 |
| `/tmp/esheep-v2-final-db2.log` | 通过 | 最新 SQL 门禁：9 个 pgTAP 文件、`planned=255, todo=1, failed=0`；advisors 无问题。lint 仍有 6 条 advisory（3 条既有函数 volatility、3 条旧函数未使用局部变量），没有把 advisory 当成失败。 |
| `/tmp/esheep-v2-final-db3.log` | 通过 | 清理 V2 新迁移中两个未使用局部变量后的 SQL 门禁：9 个 pgTAP 文件、`planned=255, todo=1, failed=0`；advisors 无问题。lint 收敛为 4 条 advisory（3 条既有函数 volatility、1 条历史迁移未使用局部变量），未修改历史迁移文件。 |
| `/tmp/esheep-v2-db-after-executable-readiness.log` | 通过 | readiness 改为可执行分发探针/投影路由后重建本地数据库并重跑 9 个 pgTAP 文件；新增门禁断言通过，`planned=259, todo=1, failed=0`，advisors 无问题。lint 有 5 条非阻断 advisory（既有 volatility、dispatch 未使用参数和历史函数局部变量），未修改历史迁移。 |
| `/tmp/esheep-v2-db-semantic-hardening2.log` | 通过 | 服务端字段观察/字段值合同、照护/TMR 主流绑定、删除/照片生命周期前置条件重建本地数据库并重跑 9 个 pgTAP 文件；`planned=262, todo=1, failed=0`，schema lint 无错误、advisors 无问题。仍保留 5 条非阻断历史/volatility advisory，未修改历史迁移。 |
| `/tmp/esheep-v2-final-static.log` | 通过（本地占位符模式） | 最新静态门禁：80/80 覆盖、品牌边界、本地化、Privacy Manifest 和 diff 检查通过；`VERIFY_ALLOW_LEGAL_PLACEHOLDERS=1` 仅用于本机验证，正式发布仍被法律占位内容阻断。 |
| `/tmp/esheep-v2-final-static2.log` | 通过（本地占位符模式） | 文档更新后的最终静态重检；同样为 80/80，品牌/本地化/Privacy Manifest/diff 全部通过，法律占位内容仍只在显式本地验证模式放行。 |
| `/tmp/esheep-v2-final-static3.log` | 通过（本地占位符模式） | 响应边界保护后的最终静态重检；80/80、品牌/本地化/Privacy Manifest/diff 全部通过，正式发布仍需先补齐法律占位内容。 |
| `/tmp/esheep-v2-final-static4.log` | 通过（本地占位符模式） | 清理 V2 SQL 局部变量后的静态重检；80/80、品牌/本地化/Privacy Manifest/diff 全部通过，正式发布仍需先补齐法律占位内容。 |
| `/tmp/esheep-v2-static-semantic-hardening.log` | 通过（本地占位符模式） | 服务端语义合同测试和照片生命周期校验后的静态重检；80/80、品牌边界、本地化、Privacy Manifest 和 diff 检查通过。正式发布仍需补齐法律占位内容。 |
| `/tmp/esheep-v2-real-static-avatar-fix-20260904.log` | 通过（本地占位符模式） | 五个新增头像关系恢复后的静态重检；80/80、品牌边界、本地化、Privacy Manifest 和 diff 检查通过。正式发布仍需补齐法律占位内容。 |
| `/tmp/esheep-v2-final-focused3-20260903.xcresult` | 通过 | 最新 V2 聚焦 XCTest：`Executed 35 tests, with 0 failures`。日志仍有迁移测试夹具清理时 SQLite vnode unlink 警告（测试生命周期噪声，未导致测试失败或活动牧场数据被修改），因此不宣称“无警告”。 |
| `/tmp/esheep-v2-final-focused5-20260903.xcresult` | 通过 | 两处响应边界保护后的增量编译与 V2 聚焦 XCTest；`Executed 35 tests, with 0 failures`。编译目的地使用当前存在的测试模拟器 ID；迁移夹具的 SQLite vnode unlink 警告仍仅属于测试清理生命周期噪声。 |
| `/var/folders/dh/kmxczty56xv16q83g8nkf_300000gn/T/esheep-v2-pause-tests.XXXXXX.nNSIcAqRgj/V2Tests.xcresult` | 通过 | 首次接收暂停/恢复语义、头像处理项、安全保存状态、命令路由等 V2 聚焦 XCTest；`Executed 37 tests, with 0 failures, 0 skipped`。包含取消后会话保持 paused、失败次数不增加且活动牧场不被污染的回归；日志仍有既有 SQLite vnode unlink 测试清理警告。 |
| `/tmp/esheep-device-evidence/v2-xctest-after-pause.log` | 通过 | 与上项对应的可读测试日志；新增暂停用例通过，整套 V2 测试 `37/37`。 |
| `/tmp/esheep-v2-pause-resume.DgDeHU/DerivedData/Logs/Test/Test-eSheepNext-2026.09.03_16-50-53-+0800.xcresult` | 通过 | 修正暂停会话恢复和重复入场记录后的增量 V2 XCTest；`ESheepCloudV2Tests` `37/37`，`** TEST SUCCEEDED **`。证明本次 Swift 改动可编译并通过现有 V2 回归；不替代真实设备/真实牧场验收。 |
| `/tmp/esheep-v2-pause-resume.DgDeHU/DerivedData/Logs/Test/Test-eSheepNext-2026.09.03_16-56-17-+0800.xcresult` | 通过 | 恢复候选按最高牧场 generation 稳定选择后的增量 V2 XCTest；`ESheepCloudV2Tests` `37/37`，`** TEST SUCCEEDED **`，命令退出码 `0`。 |
| `/tmp/esheep-v2-pause-resume.DgDeHU/DerivedData/Logs/Test/Test-eSheepNext-2026.09.03_16-59-58-+0800.xcresult` | 通过 | 加入“继续接收资料”入口后的增量 V2 XCTest；`ESheepCloudV2Tests` `37/37`，`** TEST SUCCEEDED **`，命令退出码 `0`。覆盖暂停/失败会话恢复入口编译与状态回归；不替代真实设备/真实牧场验收。 |
| `/tmp/esheep-v2-pause-resume.DgDeHU/V2Tests-ui-retry.log` | 通过 | 对应的可读测试日志；聚焦 `ESheepCloudV2Tests` 共 37 条用例通过，未发生失败或跳过。 |
| `/tmp/esheep-v2-static-pause-resume.log` | 通过（本地占位符模式） | 暂停会话恢复修复后的最终静态门禁：80/80、品牌/供应商边界、本地化、Privacy Manifest 和 diff 检查通过；法律占位内容仍只在本机显式放行，正式发布继续阻断。 |
| `/tmp/esheep-v2-static-pause-resume-ui.log` | 通过（本地占位符模式） | 加入“继续接收资料”入口后的静态重检；80/80、品牌/供应商边界、本地化、Privacy Manifest 和 diff 检查通过。法律占位内容仍只在本机显式放行，正式发布继续阻断。 |
| `/tmp/esheep-v2-static-after-executable-readiness.log` | 通过（本地占位符模式） | 移除批量 readiness 标记后的静态门禁；品牌边界、隐私、本地化、差异检查和 80/80 覆盖均通过。正式发布仍需补齐法律占位内容。 |
| `/tmp/esheep-v2-static-after-executable-readiness-final.log` | 通过（本地占位符模式） | 数据库门禁完成后再次执行的最终静态门禁；品牌边界、隐私、本地化、差异检查和 80/80 覆盖均通过。正式发布仍需补齐法律占位内容。 |
| `/tmp/esheep-device-evidence/all-xctest-after-projection.log` | 通过 | 投影边界重构后的完整 iOS 回归：主测试 `539/539`，性能测试 `6/6`，合计 `545/545`，0 失败、0 跳过。日志包含既有 CoreData/模拟器图像环境告警，因此不宣称零告警。 |
| `/var/folders/dh/kmxczty56xv16q83g8nkf_300000gn/T/esheep-v2-projection-tests.XXXXXX.cJ2zlnCvAZ/AllTests.xcresult` | 通过 | 对应完整 XCTest 结果包；`passedTests=545`、`failedTests=0`、`skippedTests=0`。 |
| `/tmp/esheep-v2-db-after-restart2.log` | 未通过（已修正） | 第一次重试的跨账号测试夹具使用了错误 JWT 用户，得到 `permission_denied`；已修正测试夹具并由 `db-final4` 重跑通过。 |
| `/tmp/esheep-v2-web-final.log` | 通过 | Web 主测试 50/50、Sites Worker 测试 6/6；依赖审计仍报告 1 个 high 级 Browserslist advisory，需依赖升级后再作正式发布门禁。 |
| `/tmp/esheep-v2-backend-final.log` | 通过 | backend 测试 33/33；依赖审计报告 1 个 moderate 级 `qs` advisory，未达到当前脚本的 high 级失败阈值，正式发布前仍应升级依赖。 |

## 暂不具备的现场证据

以下项目按用户当前条件暂缓，保持发布阻断，不用模拟器替代：

- iPhone Air 与第二台真实设备的双设备并发修改；
- 离线连续拍摄至少 200 张照片、头像设置/取消/恢复、切后台、强制结束和重启后的真实收敛；
- 25,000 条逻辑记录首次接收以及受控 20 Mbps 网络下 90 秒进入牧场；
- 真实网络下 Realtime 不可用时的事件拉取回退时延；
- 真实云端影子迁移、照片哈希对账和 authority generation 原子切换。

因此当前状态是“代码与本机自动化继续收口”，不是“V2 已完成发布”或“真实牧场已经切换”。现场验收暂缓不会被模拟器、静态检查或本地历史数据库结果替代。

## 恢复本地数据库门禁

数据库门禁只允许绑定本地 Supabase 容器，命令会 reset 本机数据库，不含远端 link/push：

```sh
ALLOW_LOCAL_DB_RESET=1 VERIFY_PUBLIC_CONFIG=0 \
  VERIFY_ALLOW_LEGAL_PLACEHOLDERS=1 \
  tools/verify_local.sh db
```

在执行前需先让 Colima/Docker 的虚拟机文件系统恢复可写。成功后应更新本记录中的日志路径和 pgTAP 数量；失败时记录实际 I/O 错误，不能跳过数据库门禁。

## 真实牧场切换仍需的最后顺序

1. 只读备份本地 store、WAL/SHM、资源 manifest，并做 `quick_check`。
2. 服务端影子转换 V1 数据，完成分类数量、摘要、关联、事件 head 和资源哈希对账。
3. 五个新加头像关系已从 Air 照片资产恢复并纳入快照，不再作为人工决策门；继续完成历史归档行的资产/投影对账。
4. 新客户端 staging 接收并校验完整快照；通过后才能进入最后确认页。
5. 现场确认一次后，才允许服务端事务锁定牧场、关闭旧写入口并启用 V2 authority generation。

第一条 V2 业务事实被接受后，旧副本不再恢复为权威，只能向前修复；旧数据和备份按计划保留至少 90 天。
