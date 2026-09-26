# Apple Design 第一轮界面优化

日期：2026-09-26。用户批准第一轮范围：称重表单、羊只详情、工作台共用行组件。

## 实现

- 称重：缺少对象、空体重及非正数在字段旁提示；选中耳号后切换到体重输入；连续保存后重置提示并回到耳号。继续复用 ProductionEntrySession 和 FarmCommandService，保留草稿、回执及云确认语义。
- 羊只详情：紧凑身份卡突出耳号、状态和圈舍；最近体重显示测量日期并进入体重与增重详情；最近三条事件下提供完整历史入口；档案和照片默认折叠。照片预览、拍照、相册添加、修改时间、删除及权限检查保留。
- 工作台：录入入口采用动词名称并移除导航箭头；管理入口保留箭头。共用行增加即时按压背景和禁用态，不缩放文字，不新增弹跳。
- 四标签、首页指标展开、分析入口和生产提交服务保持原有行为。

## 修改文件

- eSheepNext/Features/Workspace/FarmRecordsView.swift
- eSheepNext/Features/Herd/HerdViews.swift
- eSheepNext/Features/Shared/ProductionEntry.swift
- eSheepNext/Features/Shared/SheepEarTagSearch.swift
- eSheepNext/Features/Shared/SettingsStyleComponents.swift
- eSheepNext/Features/Workspace/FarmWorkbenchView.swift

## 备份与既有改动

源文件备份：`backups/20260926-114847-skill-backup`。备份反映修改前工作区，保留已有的性能优化等未提交更改。本轮差异见该目录的 `this-task.patch`。

## 验证记录

- Swift 语法检查通过。
- `git diff --check` 通过。
- Debug Simulator 构建、安装和启动通过。
- 使用 `--design-acceptance` 的隔离本机牧场；远端连接关闭。
- 原 iPhone 18 Pro 模拟器出现并行界面操作后，改用 iPhone 18 Pro Max。
- `DesignExperienceTests` 11 项、`SheepDetailSnapshotActorTests` 2 项、`SheepEarTagSearchTests` 7 项，共 20 项通过、0 失败。XcodeBuildMCP 的外层调用在重建期间超时，但底层日志明确记录 `TEST EXECUTE SUCCEEDED`。
- 模拟器实际打开称重表单；空表单点保存后，在耳号和体重字段旁分别出现可访问的错误提示。实际点击搜索结果时发现行内留白点击不稳定，已把整行作为命中区域并重新构建、安装、启动成功；该点击路径的重测仍受模拟器输入间歇性失效影响，未记为已通过。
- 从首页进入羊群并打开 QA-001 详情，视觉检查了紧凑身份卡、最近体重、快捷操作、事件记录及档案入口。截图：`backups/20260926-114847-skill-backup/sheep-detail.png`。
- Device Hub 读取超时，因此没有物理设备视觉验收证据。模拟器 XcodeBuildMCP 后续存在偶发点击和文本输入无响应，不能把工具返回的操作成功当作业务提交验收通过。

## 后续设计范围

本轮不包括上一轮评估中的分析条件收纳、搜索最近访问、全局大字号专项和图表选点。发布流程不在本轮范围。

## iPhone 18 Pro 覆盖安装

- 目标：真实 iPhone 18 Pro（iPhone19,2），iOS 27.0。
- 构建：Debug，`eSheep+ Dev` 3.2（26），Bundle ID `com.sheepfarm.next.dev`。App 与 Widget 的签名校验通过，目标设备在开发 provisioning profile 中。
- 安装与启动：`devicectl` 覆盖安装成功；主 App 和 Widget 进程均可查到。没有卸载应用或清除设备内容。
- 数据核对：安装前后 `eSheepNext.store` 均存在且大小为 34,869,248 字节，WAL/SHM 仍存在；`group.com.sheepfarm.next.dev` 的容器路径不变。iOS 重新分配了主 App 数据容器路径。
- 本次完成安装与进程检查，没有通过 Device Hub 检查真机页面或执行交互路径，因此不记为真机视觉验收。
- 构建日志、签名 App、安装回执、安装前后容器清单和进程清单保存在本机外部开发证据目录。
