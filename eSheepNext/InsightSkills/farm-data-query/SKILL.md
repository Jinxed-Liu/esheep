---
name: farm-data-query
description: 将牧场自然语言问题转换成有明确业务口径、数据来源和证据的本地查询；用于数量、明细、分组、趋势和关联条件查询，不用于写入牧场数据。
---

# 牧场数据查询技能

先确定用户要问的业务指标，再构造查询。模型不得直接把相似字段当成同一个指标。

## 核心语义

- `born_lambs`：出生羔羊数。来源固定为 `ReproductionRecord(kind=lambing).lambCount` 的合计。
- `born_lamb_lifecycle`：按出生月份查询出生数及当前在群、死亡、出售、淘汰、转出。出生数来自产羔事件 `lambCount`；生命周期数量来自具有出生日期的羊只档案和离群记录。两种来源必须分列，不得假设能逐只对应或强行相减。
- `lambing_events`：产羔次数。来源固定为产羔事件条数。
- `sheep_profiles`：羊只档案数量或档案字段。`birthAt` 只表示档案中的出生日期，不代表本牧场产羔数。
- 其他查询使用 `weight_records`、`reproduction_records`、`health_records`、`feeding_records` 或 `inventory`。

## 工作流

1. 识别指标、时间范围、分组、筛选及关联条件。
2. 调用 `query_farm_data`，必须填写 `query_kind`。
3. 技能根据 `query_kind` 固定真实数据源，并覆盖冲突的 `subject`、`kind`、`date_field` 和 `metric`。
4. App 在执行前校验 `query_kind` 是否符合当前用户问题；不符合时拒绝执行并要求重查。
5. App 本地执行 SwiftData 查询和计算，返回数据源、筛选条件、截止时间及完整性。
6. 如果查询结果的 `query_kind` 与用户指标不一致，结果不得展示，必须重查。

## 边界

- 不允许用羊只档案出生日期替代产羔事件。
- 不允许把产羔次数替代出生羔羊数。
- 不知道分母、时间字段或生命周期口径时，说明缺少条件；不得用近似统计补齐。
- 当前设备本地数据不等于云端已经同步完成，结果必须保留数据来源说明。
