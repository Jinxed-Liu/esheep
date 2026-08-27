# 2026-08-28 XCTest 验证记录

## 验证对象

- 分支：`codex/performance-staged`
- 性能提交：`42abf75`（CloudKit runtime 延迟创建）
- 工具链：Xcode 27.0 Beta（`27A5237l`），仅作诊断证据
- 设备：iPhone 17 Pro 模拟器，iOS 27.0（`24A5408d`）
- 配置：Debug，项目原始环境配置，正常模拟器签名
- 执行方式：单 worker，先构建后执行；未配置生产数据库 reset、迁移或写入步骤

## 问题与修复证据

最初的完整测试宿主在任何 XCTest 方法开始前崩溃。崩溃栈定位到
`CloudSyncActor.init` 第 352 行的 `CKContainer(identifier:)`，上游为
`CloudCollaborationStore.init` 和 `AppBootstrapController.prepareStore`。这说明
测试没有失败在业务断言，而是 App 启动时提前建立了未使用的 CloudKit runtime。

修复后，纯本地恢复测试会直接构造 `CloudSyncActor`，执行恢复标记的 CAS 状态
转换，并断言前后均未创建 CloudKit runtime。真实 CloudKit 操作仍通过原有
container identifier、private/shared database、`CKSyncEngine` serialization 和
startup repair 建立 runtime。

## 最终结果

| 项目 | 结果 |
| --- | ---: |
| 发现测试 | 595 |
| 通过 | 594 |
| 失败 | 0 |
| 跳过 | 1 |
| 预期失败 | 0 |
| Runtime warning | 0 |
| 提交后复跑耗时 | 33.224 秒 |

唯一跳过项是仓库已有的 iOS 27 Beta CloudKit trap 保护用例；同文件中的系统分享
fallback 回归已执行。当前 `xcresult` 总结状态为 `Passed`。正式发布门禁仍必须在
项目认可的稳定 Xcode 上重跑，并要求 0 跳过；本记录不能替代签名 Archive、
TestFlight、真机交互或 Instruments 结果。

## 可复现命令形态

```sh
xcodebuild build-for-testing \
  -project eSheepNext.xcodeproj \
  -scheme eSheepNext \
  -configuration Debug \
  -destination '<同一模拟器>' \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1

xcodebuild test-without-building \
  -project eSheepNext.xcodeproj \
  -scheme eSheepNext \
  -configuration Debug \
  -destination '<同一模拟器>' \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1
```

不要为第二步设置 `CODE_SIGNING_ALLOWED=NO`：凭据保险箱测试需要正常模拟器签名。
不要为 Debug 测试覆盖 `CLOUD_COLLABORATION_ENABLED`：环境契约测试会校验项目嵌入
的真实配置。

## 后续性能目标合并复验

提交 `a58f28c` 新增独立 `eSheepNextPerformanceTests` 目标后，使用同一模拟器、
Debug 配置和单 worker 再次运行完整 scheme：共发现 601 项，600 项通过、0 项失败、
1 项仍按上述 beta 保护逻辑跳过，xcresult 报告 0 runtime warning。6 项性能用例均
采集到 clock、CPU 和 memory 指标；详细 fixture 与数值见
`docs/performance/2026-08-28-xctest-performance.md`。
