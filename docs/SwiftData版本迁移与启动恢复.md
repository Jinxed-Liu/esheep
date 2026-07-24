# SwiftData 版本迁移与启动恢复

## 当前基线

- 正式 Schema 版本为 `1.0.0`，由 `AppSchemaV1` 声明。
- `AppSchemaMigrationPlan` 是所有持久化容器的唯一迁移计划。
- V1 冻结引入正式版本管理时的现有模型，没有业务模型改写或数据回填。
- 打开或迁移数据库不会创建 `DomainOperation`、`OutboxItem` 或任何云端业务操作。

## 后续版本规则

1. 新版本必须新增 `VersionedSchema`，不得修改已经发布版本的模型列表。
2. 可选字段或具有稳定默认值的新增优先使用 lightweight stage。
3. 重命名、类型变化、拆分、合并和业务回填必须使用 custom stage，并使用旧数据库夹具验证。
4. 本地迁移、云载荷兼容、Outbox 语义必须分别测试，不能用其中一项代替其余两项。
5. 新旧客户端需要并行运行时，云载荷必须保持向后可解码，或者由明确的协议版本门禁拒绝。

## 启动失败处理

- 容器初始化失败时 App 显示数据恢复页，不再调用 `fatalError`。
- “重新尝试打开”不会修改数据库。
- 诊断报告只包含 App/系统/Schema 版本、数据库文件名和错误域/代码，不包含令牌、私钥、牧场名称或业务数据。
- “隔离旧数据库并进入恢复”必须由用户二次确认。操作把 `.store`、`-wal`、`-shm` 和 `_SUPPORT` 原样移动到 `Application Support/RecoveryQuarantine/<timestamp>`。
- 任一文件移动失败时应回滚已经移动的文件；不能回滚时必须停止并保留现场。
- 隔离成功后 App 创建新的空数据库，用户重新登录后使用现有本地完整备份或已验收的云端恢复。

## 发布门禁

- 使用真实旧版本数据库验证升级前后实体数量、最高 revision、Outbox、Tombstone、照片和关键业务摘要。
- 注入无法写入、损坏数据库和不支持版本，确认原数据库不会被自动删除。
- 在正式非 Beta Xcode 上执行 `AppSchemaMigrationTests` 和完整 XCTest。
