# 账号头像界面重设计 · 2026-09-18

范围：原生 iOS 的账号头像、“我的”顶部头像入口、选图及裁剪确认。沿用当前源码 AppTheme 配色。

## 完成内容

- 默认头像使用浅色底和姓名首字，深色模式提高对比度。
- 设置页移除头像上的相机徽章、重阴影和头像下方的文字入口，头像本身是进入编辑页的唯一入口。
- 个人头像页使用独立大预览、账号名称、同步说明与底部主按钮，隐藏此详情页的底部 Tab 栏。
- 相册选择后进入裁剪确认页。支持拖动、双指缩放、缩放滑块、重新居中及 VoiceOver 方向操作。
- 预览与 384×384 JPEG 导出共用坐标计算，缩放范围 1–4 倍，边缘限制防止露白。选图以 ImageIO 归正方向、降采样至最长边 2048 像素。
- 点击“使用这张头像”才调用已有头像云服务；失败时保留照片和裁剪位置。编辑页不提供恢复默认头像操作，避免增加无必要的破坏性动作。
- 仅扩展已有 DEBUG 隔离验收入口，便于直接查看账号设置、头像详情、裁剪页；裁剪截图使用项目内测试插图。

## 验证

- 最终 Debug 模拟器编译成功；改动代码无编译警告。已有 Widget 签名 stripping 提示保留。
- AccountAvatarCropTests 5/5：极端拖动不露白、不同视口与导出坐标一致、红蓝色块实际裁剪像素、3000 像素旋转图片降采样/方向归正、无效图片拒绝。
- AccountAvatarCloudSyncTests 4/4：既有本地头像上传、较新远端头像接收、远端移除、异常响应保留原数据；使用 stub，不代表真实云端验收。
- 最终针对性测试共 9/9 通过，0 失败、0 跳过。
- 在 iPhone 18 Pro / iOS 27 模拟器的隔离账号中查看设置页、个人头像页、裁剪页，检查深色与 accessibility3 大字号。裁剪页大字号可滚动到“重新居中”，主按钮保持可见。系统相册成功展示。
- Swift 语法检查和改动文件 diff 空白检查通过。
- 尚未验证：真实相册选图至上传的完整交互、真机视觉、真实账号跨设备上传/同步；本次真机安装只证明构建、签名、安装和启动。

## 截图

| 账号设置 | 个人头像 | 裁剪预览 |
|---|---|---|
| ![账号设置](/Volumes/移动硬盘/eSheepNext-Dev/Screenshots/account-avatar-20260918/settings-light.png) | ![个人头像](/Volumes/移动硬盘/eSheepNext-Dev/Screenshots/account-avatar-20260918/avatar-light.png) | ![裁剪预览，测试插图](/Volumes/移动硬盘/eSheepNext-Dev/Screenshots/account-avatar-20260918/crop-light.png) |

大字号深色截图：[个人头像](/Volumes/移动硬盘/eSheepNext-Dev/Screenshots/account-avatar-20260918/avatar-dark-large.png)、[裁剪预览](/Volumes/移动硬盘/eSheepNext-Dev/Screenshots/account-avatar-20260918/crop-dark-large.png)。

## 备份与证据

- 原账号界面备份：`backups/20260918-194835-skill-backup/`
- 既有隔离验收入口备份：`backups/20260918-195931-skill-backup/`
- 构建产物：`/Volumes/移动硬盘/eSheepNext-Dev/BuildArtifacts/account-avatar-20260918/`
- 最终测试日志：`/Users/jinxliu/Library/Developer/XcodeBuildMCP/workspaces/eSheepNext-268a4a5886a1/logs/test_sim_2026-09-18T12-02-43-172Z_pid81701_7a632663.log`
- 最终测试结果：`/Users/jinxliu/Library/Developer/XcodeBuildMCP/workspaces/eSheepNext-268a4a5886a1/result-bundles/test_sim_2026-09-18T12-02-43-172Z_pid81701_5abfec83.xcresult`
- 最终编译日志：`/Users/jinxliu/Library/Developer/XcodeBuildMCP/workspaces/eSheepNext-268a4a5886a1/logs/build_sim_2026-09-18T12-03-29-293Z_pid81701_c900a76d.log`

当前工作区已有其他未提交改动；本次未提交 Git，未修改模型、账号云服务或任何生产数据。


## iPhone 18 Pro 真机安装跟进

2026-09-18 应用户“安装到18pro”请求，重新查询并确认物理设备「刘妙妙的iPhone」（iPhone19,2 / iOS 27.0），UDID `00008160-0011503211800036`。

- 真机 Debug 构建成功，`codesign --verify --deep --strict` 通过。
- 覆盖安装 `com.sheepfarm.next.dev`，版本 `3.1.1 (24)`，安装成功；没有卸载或清理设备数据。
- 正常启动成功，未传入隔离测试启动参数；安装后应用清单复核通过。
- 未执行真实头像上传、移除或跨设备同步验收，真机界面的视觉与操作验收仍待完成。
- 构建、安装、启动及安装前后清单证据均在 `/Volumes/移动硬盘/eSheepNext-Dev/BuildArtifacts/account-avatar-20260918/iphone18pro-*`。

## 2026-09-19 反馈调整

- 按反馈移除设置页头像下方的“更换头像 >”文字入口，头像本身仍保持可点击。
- 按反馈移除头像编辑页的“恢复默认头像”按钮、确认弹窗及界面状态；保留底层云同步删除接口和既有协议测试，不让这次 UI 调整影响同步兼容性。
- 按 2026-09-19 截图反馈移除头像页底部“选好照片后，可以调整显示范围”提示，只保留“从相册选择”按钮。
- 按 2026-09-19 反馈将“从相册选择”和“使用这张头像”改为 iOS 26 原生 Liquid Glass 主按钮，保留胶囊形、加载态和禁用态。
- 针对性测试重新执行 9/9 通过；真机 Debug 构建、严格签名校验、覆盖安装和启动均通过。新证据在 `/Volumes/移动硬盘/eSheepNext-Dev/BuildArtifacts/account-avatar-20260919/`，启动截图为 `iphone18pro-after-launch.png`。
- 本次样式版头像裁剪与云同步专项测试 9/9 通过；模拟器视觉截图为 `simulator-avatar-liquid-glass.png` 与 `simulator-avatar-crop-liquid-glass.png`，真机覆盖安装记录为 `iphone18pro-install-liquid-glass.json`。
