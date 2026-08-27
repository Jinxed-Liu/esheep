# 2026-08-28 Supabase 隔离数据库验证与查询计划

## 隔离边界

- 验证源是 `codex/performance-staged` 当前已提交树的临时导出，不读取或写入工作区中
  未提交的法律、隐私 migration 和 pgTAP 文件。
- 临时项目 ID 为 `eSheepNextPerfAudit20260828`，数据库端口为 `56322`；只启动独立
  PostgreSQL 容器。现有 `eSheepNext`、其他项目和任何远端 Supabase 实例均未停止、
  reset、link 或 push。
- 验证完成后停止临时项目并删除其匿名数据卷和临时源目录；生产数据没有导入或导出。

该流程遵循 Supabase 的[本地数据库测试与 lint](https://supabase.com/docs/guides/local-development/cli/testing-and-linting)
边界：migration、pgTAP、lint 和 advisors 都显式绑定本地临时实例。

## Migration、pgTAP、lint 和 advisors

| 门禁 | 结果 |
| --- | --- |
| 从空库启动 | 当前已提交的 28 个 migration 全部成功应用 |
| `supabase db reset --local` | 成功从空库再次应用 28 个 migration |
| pgTAP | 4 个文件、79 条计划断言、0 失败、1 条既有 TODO |
| `supabase db lint --local --fail-on error` | 通过；1 条 warning：`stage_farm_projection_batch` 中 `v_transition` 从未读取 |
| security advisor | 0 error、0 warn；1 条 INFO：`icloud_capability_certificates` 启用 RLS 且无客户端 policy |
| performance advisor | 0 error、0 warn；仅 fresh fixture 中尚未命中的 `unused_index` INFO |

`icloud_capability_certificates` 没有开放客户端 policy 是当前默认拒绝边界，不在本批为
消除 INFO 而放宽。fresh fixture 只执行当前 Web/同步读取形状，不能用其中的
`unused_index` INFO 推断生产索引无用；因此没有删除现有权限、迁移、设备、邀请、
Outbox 或检查点索引。

## 匿名数据规模

临时库只包含固定匿名 UUID 和生成 payload，不包含耳号、账户、牧场名、照片或任何
真实业务数据。

| 数据集 | `farm_entities` | `farm_operations` | compact checkpoints |
| --- | ---: | ---: | ---: |
| 1× fixture | 10,000 | 20,000 | 100 |
| 10× fixture | 100,000 | 200,000 | 1,000 |

实体均匀分布在 sheep、pen、feed、transfer、removal、weight、feed ingredient、TMR
formula、TMR plan 和 farm 十类；5% 实体为删除态，2% 操作为删除态。执行计划前对五张
相关表运行 `ANALYZE`。

## `EXPLAIN (ANALYZE, BUFFERS)` 结果

以下是同一温热本地实例的单次服务端执行时间，用于识别扫描和排序形状，不代表公网
延迟或 Staging P95。

| 真实读取形状 | 1× | 10× | 计划摘要 |
| --- | ---: | ---: | --- |
| 按 farm + entity type 读取 1,000 个活动实体，按 modified time/ID 倒序 | 1.142 ms | 7.100 ms | 现有复合主键定位；10× 扫描 10,000 个同类实体，top-N 排序 181 KB、无磁盘排序 |
| 按 farm + authority 读取 1,000 个活动操作，按 revision/ID 倒序 | 0.557 ms | 0.405 ms | `farm_operations_farm_id_revision_key` 反向扫描并增量排序 |
| 读取最新 compact checkpoint | 0.013 ms | 0.012 ms | `farm_checkpoints_farm_generation_idx` 反向扫描，3 个 shared buffer hit |
| `list_my_active_farm_access()`，2 个可访问牧场 | — | 1.067 ms | RLS 身份下 Function Scan；返回 2 行 |

10× 操作查询比 1× 更快是温热缓存和单次采样噪声，不能解释为规模越大越快；两者都
证明当前读取只访问约 1,000 行并使用既有索引。最慢的 10× 实体页仍为 7.10 ms，未
出现磁盘排序、全表顺序扫描或接近 1 秒的服务端耗时。

## 决策

- 本批不增加组合索引。现有计划已满足当前匿名规模，新增索引会增加写放大和 migration
  风险，却没有可测量热点证据。
- 本批不增加 `workspace_overview_v1`。Web 首屏包体已达标，隔离数据库查询也未触发
  “概览 ready P95 高于 1 秒”的条件；是否需要 RPC 仍由 Staging 的网络与完整 payload
  P95 决定。
- 仍需在不导出真实数据的前提下，于 Staging 或受控真实规模环境记录 RLS、网络、
  checkpoint 下载/解压和 JSON 投影的端到端时间。届时若计划形状变化，索引或 RPC
  必须作为独立追加 migration，并保留现有读取 fallback。
