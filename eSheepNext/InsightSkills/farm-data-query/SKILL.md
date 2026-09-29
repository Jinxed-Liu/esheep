---
name: farm-data-query
description: 回答牧场数量、明细、趋势和派生计算问题；仅在需要明确业务口径及可核查证据的只读查询时使用。
---

# 牧场事实查询

先确定指标、时间、筛选、分组与对象。直接明细或单表聚合用 `query_farm_data` 并指定 `query_kind`；相邻记录、差值、时间间隔和变化率用 `calculate_farm_data` 的类型化算子计划。App 的 `FarmDataQuerySkill.swift`、查询引擎及工具契约负责校验与执行；不要按自然语言别名新增字符串路由。

## 不可混淆的口径

- `current_herd` 是 App 统一状态投影中的当前在群羊只，排除历史归档；不能仅凭“没有离群事件”判断在场。
- `born_lambs` 合计产羔事件 `lambCount`；`lambing_events` 统计产羔事件条数；`sheep_profiles.birthAt` 只是档案出生日期。三者不能互代。
- `born_lamb_lifecycle` 将产羔事件的出生总数与有出生日期档案的当前在群、死亡、出售、淘汰、转出分列。两套来源无法保证逐只对应，不能直接相减。
- 历史圈舍表现用 `cohort=all_profiles` 与 `pen_membership=at_measurement`；当前仍在群羊只用 `current_in_herd` 与 `at_cutoff`。相邻称重区间要在完整时间线上验证圈舍归属，不能删掉中间样本再拼区间。批次跨越、重叠或缺失须单列。
- 未被用户收窄的群体变化率使用 `analysis_scope=complete` 和同羊真实相邻称重区间，返回总体、区间、批次、截止时点生命周期及数据完整性。首末平均值只能补充。

## 回答边界

所有条件都须由工具实际执行；不能执行时说明缺口或拒绝近似结果。日期和月份使用牧场保存的 IANA 时区。报告数据来源、口径、样本及未知数；本地数据不代表云端已同步。把工具证据转成针对原问题的直接答案，不原样转述工具输出。
