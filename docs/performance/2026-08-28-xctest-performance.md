# 2026-08-28 离线 XCTest 性能基线

## 目标与边界

- 可回退提交：`a58f28c`（`Add offline iOS performance test target`）。
- 新增独立 `eSheepNextPerformanceTests` unit-test target，并纳入主 scheme；目标设置为
  不并行运行，继续使用 Swift 6 完整严格并发检查。
- 所有数据来自临时内存 SwiftData container 或测试内生成的 JPEG；不恢复用户账号、
  不访问 Supabase/CloudBase/CloudKit、不写生产数据库，也不导出真实牧场数据。
- 每个测量先做一次不计时的等价性预热，再记录 5 次 steady-state clock、CPU 和
  memory 指标。它用于发现代码回退，不代表冷启动、真机 P95 或峰值内存验收。

Apple 的 [XCTest performance tests](https://developer.apple.com/documentation/xctest/performance-tests)
以同步测量 block 采集选定 metrics；本目标通过有超时和错误传递的桥接等待 actor
完成，把完整 snapshot/decode 工作包含在测量窗口内。

## 匿名 fixture

| 用例 | 主要规模 | 等价性断言 |
| --- | --- | --- |
| 耳号搜索 | 20,000 个 Sendable 候选 | 结果、总命中数和前 8 排序与预热结果一致 |
| 首页快照 | 2,000 只羊、24 圈、600 投喂、400 健康、120 Outbox | 在场羊 2,000、占用圈舍 24，完整快照一致 |
| Care 摘要 | 200 只母羊、1,000 健康、1,000 繁殖事实 | 健康 1,000、排除胎次基准后繁殖 800 |
| 投喂摘要 | 800 投喂、2,400 明细、400 余料观察 | 今日投喂 800，快照与预热结果一致 |
| 单羊历史 | 1,500 称重、1,000 转群、1,000 tombstone、20 圈 | 有效称重/转群数量及投影摘要一致 |
| 图片下采样 | 测试内生成 2,048 × 2,048 JPEG | 每轮使用新 digest，输出长边不超过 320 px |

## 当前诊断数值

环境：Xcode 27.0 Beta（`27A5237l`）、iPhone 17 Pro 模拟器、iOS 27.0
（`24A5408d`）、Debug、单 worker。以下是完整 601 项复验中 5 次 monotonic clock
的中位数：

| 用例 | 中位数 |
| --- | ---: |
| 20,000 候选耳号搜索 | 7.81 ms |
| 首页快照 | 41.41 ms |
| Care 摘要 | 16.61 ms |
| 投喂摘要 | 41.62 ms |
| 单羊历史投影 | 42.12 ms |
| 2,048 px JPEG 下采样到 320 px | 3.12 ms |

6/6 性能用例通过；合并后的完整 scheme 为 601 项发现、600 项通过、0 项失败、
1 项按既有 beta 保护逻辑跳过，xcresult 为 Passed 且 runtime warning 数为 0。
Core Data 迁移 fixture 仍会在原有迁移用例日志中输出“migration completed by another
client”诊断文字，但 xcresult 未把它归类为 runtime warning，相关迁移断言全部通过。

这些数值没有设置性能 baseline 阈值，因为 beta 模拟器不能作为发布硬门禁。待稳定
Xcode 与固定真实设备采集完成后，再以同一设备的中位数/P90/P95 设置回退阈值；真机
冷启动、hitch、主线程停顿和图片场景峰值内存仍需 Instruments 单独验收。
