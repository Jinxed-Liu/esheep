# 2026-08-28 Web 按路由装载验证记录

## 实施边界

- 可回退提交：`d851c6c`（`Load Web workspace data by route`）。
- 新增内部 `WorkspaceDataSource`，对外提供 `loadOverview`、`loadHerd`、
  `loadRecords`、`loadTMR`、`loadInsight`、`loadForPage` 和 `invalidate`。
- 请求上下文固定为 `farmID + authorityGeneration + requestGeneration`。相同上下文
  single-flight；新请求会中止旧请求，即使底层 loader 忽略 `AbortSignal`，旧响应也
  会因 generation 不再匹配而被丢弃。
- 缓存键为 `farmID + authorityGeneration + revision`；同一牧场只保留最新 revision，
  退出账号、会话恢复、显式刷新和牧场失效会精确清理。
- 本批只改变 Web 读取范围，不增加写接口，不修改 Supabase 表、RLS、
  `DomainOperation`、Outbox 或 iOS 权威切换协议。

## 页面与实体读取矩阵

| 意图/页面 | 基础读取 | 追加读取 |
| --- | --- | --- |
| 概览、录入、事件、设置 | farm、pen、sheep、feed、transfer、removal、操作历史、紧凑 checkpoint | 无 |
| 羊群、洞察 | 上述基础读取 | weight |
| 投喂、TMR、需要配方的录入弹窗 | 上述基础读取 | feedIngredient、tmrFormula、tmrFeedingPlan |

概览继续保留羊只、圈舍、投喂、转群、离场、操作历史和紧凑 checkpoint，因为首页
当前状态、最近事件、删除/恢复及历史归档投影依赖它们；没有为了减少请求而绕开历史
语义。`weight` 和三类 TMR 实体不再随概览提前下载。若真实网络测得概览 ready P95
仍高于 1 秒，再按计划评估受 RLS 约束的版本化只读 RPC；本批没有提前增加 RPC。

## 自动化结果

执行 `./tools/verify_local.sh web`：

| 项目 | 结果 |
| --- | ---: |
| Node 测试 | 14/14 通过 |
| Sites worker 复验 | 4/4 通过 |
| Vite 生产构建 | 通过，153 个模块 |
| npm audit | 0 个已知漏洞 |

新增契约覆盖：路由到实体范围、累积 section 覆盖、当前牧场隐式固定、同上下文
single-flight、快速切换牧场时丢弃迟到响应、authority generation 变化拒绝回填。

生产构建的三个初始 JavaScript chunk 为 `index` 11.45 KB、`icons` 21.23 KB、
`react` 60.54 KB，共约 93.22 KB gzip，低于 130 KB 门槛。Supabase 入口 7.20 KB、
Supabase vendor 57.42 KB 和各功能路由继续延迟加载。

## 浏览器检查与限制

在 Codex 内置浏览器打开本地 Vite 构建，桌面端依次检查首页、羊群、耳号 `23081`
筛选、TMR 和洞察页面；路由内容均可见，筛选结果收敛为 1 条，切换前后浏览器
console 的 warning/error 均为空。390 × 844 临时视口下语义树仍进入移动断点并保持
可访问，但截图出现浏览器视口缩放异常，因此本记录不把它算作移动端视觉验收。

本地浏览器运行的是仓库演示工作区，没有真实 Supabase 登录会话。因此它证明页面
拆分后的渲染与导航未退化；请求数量、取消和旧响应隔离由纯契约测试证明，真实账号、
真实网络下的请求瀑布、P95、离线/401/403 和快速牧场切换仍需在 Staging 或隔离环境
复验。
