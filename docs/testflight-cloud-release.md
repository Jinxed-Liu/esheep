# 从 main 发布内部 TestFlight

在 App Store Connect 的 Xcode Cloud 产品 `eSheepNext` 中，手动启动
`TestFlight 3.2 Internal` 工作流并选择 `main`。启动前记录 main 的完整 SHA，
确认该 SHA 的 GitHub `Repository verification` 通过，并完成当前版本的
`tools/verify_testflight_internal.sh` 门禁。

工作流使用正式版 Xcode、`eSheepNext.xcodeproj`、`eSheepNext` scheme，
执行 iOS Archive，分发准备为 `TestFlight（仅限内部测试）`，后续操作的目标组
为现有的 `3.1 Internal`。

工作流环境变量：

| 名称 | 用途 |
| --- | --- |
| `ESHEEP_TESTFLIGHT_RELEASE=1` | 启用专用发布脚本 |
| `ESHEEP_RELEASE_SUPABASE_URL` | Production 客户端 URL，已在 Cloud 保存 |
| `ESHEEP_RELEASE_SUPABASE_PUBLISHABLE_KEY` | Production publishable key，已在 Cloud 保存 |
| `ESHEEP_TESTFLIGHT_VERSION` | 可选；当前预期版本默认为 `3.2`，升级版本时同步更新 |

`ci_pre_xcodebuild.sh` 仅接受此工作流从 main 发起的手动 Archive，不接受 PR、
定时任务或检查点任务。它校验客户端配置，在临时 Cloud checkout 内生成被 Git
忽略的 Release 配置，并把 App、Widget 的构建号统一设为 `CI_BUILD_NUMBER`。
Cloud 按产品递增分配构建号，无需每次在仓库写死数字。手动启动前仍需核对
TestFlight 现有上传，避免与其他上传渠道使用的构建号冲突。

Release 的 App 和 Widget 使用自动签名，交由 Xcode Cloud 管理证书与描述文件。
无需向 GitHub 上传本机 `.p8`、`.p12` 或证书私钥。客户端配置只接受
`sb_publishable_` key，不接受服务端 secret 或 service-role key。

`ci_post_xcodebuild.sh` 检查 Archive 中的 App、Widget Bundle ID、版本和
构建号、Production 环境、客户端配置、关闭订阅、非豁免加密声明、签名和
arm64 架构，任一项不匹配即失败。检查点维护仍使用自己的显式开关与工作流。

上传后分别核验 Apple 接收、处理完成、出口合规和内部组关联；处理中的构建
尚未完成分发。如 Cloud 后续分发仍排队，可在 Apple 处理完成后，按本次已授权
的发布范围，直接在 App Store Connect 把同一构建加入 `3.1 Internal` 并重新读取
组页面确认。测试说明来自 `TestFlight/WhatToTest.zh-Hans.txt` 与
`TestFlight/WhatToTest.en-US.txt`。

GitHub Actions 的 `Repository verification` 执行静态、Web、backend 和一次性
数据库验证；iOS 归档签名及上传由 Xcode Cloud 执行。`Cloud checkpoint candidate`
依赖专用 self-hosted Mac runner，是检查点维护任务，不能作为 TestFlight 发布
工作流使用。

分发成功与真机安装、升级、登录、云同步和业务验收分别记录。该工作流仅面向
内部测试；外部测试、Beta Review、公共链接、测试员增删和 App Store 提交需要
相应的用户授权。
