# 账号头像融入刘海：实现与验证

日期：2026-10-25。本次在已有 Duo 适配和侧栏排序改动之上继续开发，未覆盖此前工作。

## 实现范围

- 新增 `SettingsAvatarNotchGeometry`，对当前支持的刘海机型选择宽、窄两种软件连接肩部；机型标识与 Xcode 设备描述文件核对，记录在 `work/avatar-notch-20261025/sdk-notch-profiles.json`。
- 当前列表覆盖 iPhone 11 / 12 系列、13 系列、14 / 14 Plus、16e / 17e。未识别的机型不启用刘海效果，不仅凭顶部安全区高度猜测刘海。
- 刘海连接使用当前窗口顶部安全区定位，并把绘制边缘延伸至传感器区域之内；它是装饰性连接范围，不声称精确测量了硬件刘海边界。
- 复用已有连续滚动进度、头像收缩、模糊和变暗效果；刘海采用较宽的连接肩部，并取消仅适合灵动岛的圆形外裁切。反向滚动使用同一组连续几何。
- 原灵动岛几何路径保留。Duo 竖向系统栏、横屏、非全宽窗口、状态栏隐藏等环境不启用顶部连接。关闭头像动画、减少动态效果和省电设置沿用原有逻辑。
- 头像点击、展开与查看、选择裁剪、保存和云同步逻辑未修改。

## 已完成的验证

最终 `xcodebuild test` 在 Xcode 27.1 / iOS 27.1 Duo 模拟器上构建并执行：

| 测试组 | 通过 | 失败 | 跳过 |
| --- | ---: | ---: | ---: |
| SettingsAvatarNotchGeometryTests | 7 | 0 | 0 |
| SettingsAvatarIslandGeometryTests | 9 | 0 | 0 |
| AccountAvatarInteractionTests | 17 | 0 | 0 |
| 合计 | 33 | 0 | 0 |

新增测试验证机型分流、无效尺寸和临时安全区回退、连接锚点、宽连接区域的绘制覆盖、完整收拢后无残留黑条，以及展开后保留完整头像和姓名扩展区。

结果包：`work/avatar-notch-20261025/notch-final-regressions.xcresult`；摘要：`notch-final-summary.json`；日志：`notch-final-regressions.log`。`git diff --check` 与中英文本地化检查通过。以上是自动测试，不能代替刘海设备上的视觉验收。

## 暂缓与证据边界

用户明确选择先完成代码和自动测试、暂缓视觉验收。本机当前只有 Duo 专用 iOS 27.1 运行时；普通 iOS 27.0 官方运行时约 8GB 的下载被当前受限网络阻止。等待中的下载已取消，未修改网络设置、未开始直链下载。

本轮没有普通刘海或灵动岛设备的视觉验收，也没有真机、Release、签名归档、上传或审核结果。后续需在刘海设备检查连接是否贴合、慢速上滑与反向下拉、头像展开、减少动态效果，以及普通灵动岛回归。环境记录见 `work/iphone-duo-20261025/ui-evidence/notch-runtime-preparation.md`。

改动前两份源文件与原工作区 diff 已保存在 `work/avatar-notch-20261025/`；当前源码和校验摘要见同目录 `source-snapshot.tar.gz`、`source-manifest.json`。生产数据和版本号未改动。
