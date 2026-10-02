# AI 助手 iOS 实现记录

日期：2026-10-01。依据：[完整设计方案](ai-assistant-ios-design-2026-10-01.md)。

本次交付是源码实现和可运行回归证据。当前环境为 Linux，没有 Xcode 或 iOS SDK，尚未完成 App 类型编译、模拟器、真机视觉对照或 TestFlight。2026-10-02 用户授权提交并合并至 main，提交与合并结果以 Git 记录为准；未部署、登录 ChatGPT 或修改实际牧场数据。

## 已实现的 App 代码

- 常规 AI 入口改为聊天列表，点击聊天进入指定会话；列表底部输入创建新聊天。首次有效发送保存成功后才创建列表记录。搜索限定当前账号、牧场及已保存的可见消息，并能定位到命中的消息。
- 列表与新聊天页共享未提交草稿，已有聊天使用各自草稿。文字、图片、文件和音频草稿使用本机加密存储。发送、取消、附件失败和恢复输入均保留明确状态，不自动重发。
- 输入框按提供的 iOS 截图采用一个圆角玻璃容器：收起胶囊、输入展开、附件及录音状态。加号菜单接入相机、照片、文件、方案模式和追求目标；键盘、焦点、动态字体、减弱透明与动画有独立适配。
- 齿轮打开独立蓝色三档滑块，默认中档。低、中、高分别控制工具轮次、请求数、累计输出、运行时间和额外复核；原生思考开关、显示思考开关单独保存。MiMo 原生能力仍为开关，三档属于 App 的分析策略。
- 设置及聊天页统一显示实际使用的 `MiMo-V2.6-Pro`。过程面板仅显示服务实际返回的思考和真实工具、复核事件，未通过审核的正文不会提前作为最终答案发布。思考及恢复检查点留在本机加密 sidecar，不进入个人空间同步。
- 前台协调器允许两个不同聊天同时计算，其余 FIFO 排队。同一会话不能启动重叠 turn；等待用户授权、操作卡、云回执或暂停时释放计算槽。返回列表继续订阅；后台、切换账号或牧场暂停，恢复必须明确继续。
- 方案模式仅查询和分析，保存结构化步骤、缺失条件与完成标准；修改保留方案版本。按方案继续启动目标，目标逐步保存证据、预算与检查点，最后另做基于真实证据的完成核验。
- 保留原操作卡、编辑、拒绝、批量确认及 Face ID。点击确认捕获完整参数和作用域快照；认证后再核对角色、参数、数据版本、设备、授权及会话。业务写入仍经过原命令与审计同步流程。
- 目标遇到操作卡等待用户确认；本机执行后依实际云意图及回执区分待确认、确认、拒绝和冲突。导出面板打开不算完成，只有保存成功回调才记录导出完成。
- 文件分析与原业务导入分开。支持 PDF、DOCX、TXT、MD、XLSX、CSV、JSON 的本机提取、选区和引用；最多三个文件、单文件 25 MiB、合计 50 MiB，选定文本合计 200 KB。解析不完整、扫描 PDF 或容量不足明确提示，不能静默截断后声称分析全文。
- 保留 App 统一称重计算规则及此前修复：多栏舍完整分析、相邻有效称重区间、日期范围、历史栏舍归属和批次边界使用确定性计算。AI 数值答案仍依据本机权威结果。
- 删除聊天阻断晚到结果；撤回 AI 同意、撤回法务同意及账号删除清理新增思考、流程、文件与草稿记录。业务历史事实和原操作回执不因聊天删除而销毁。

主要入口：`FarmInsightConversationListView.swift`、`FarmInsightConversationView.swift`、`InsightComposerView.swift`、`InsightWorkflowViews.swift`；状态和执行：`InsightSessionCoordinator.swift`、`InsightConversationController.swift`、`InsightAssistantWorkflow.swift`、`InsightRuntimeStore.swift`。Xcode 工程使用同步文件组，新源码随对应 App 目录纳入工程。

## Codex 分支的实际边界

已实现原生 HTTPS 协议客户端、独立桥凭据存储、牧场工具桥，以及 `backend/codex-bridge` 的官方 Codex app-server 适配进程。具备作用域绑定、稳定请求去重、工具回执、前台连接租约、暂停、刷新后进程重启与 thread resume。工具桥仅调用既有查询、计算或待确认草案，不批准业务操作。

真实官方 `codex-cli 0.159.0-alpha.3` 已完成 `initialize` 和 `config/read` 冒烟检查，使用隔离目录和测试 token，没有执行登录或推理。这证明适配器能启动该版本的实际进程，不证明 ChatGPT 订阅额度可用。

当前 App 聊天仍使用 MiMo；Codex 尚未接入可选择的 App 会话服务。四项准入开关默认关闭：商业接入资格、正式 iOS 授权回调、隐私说明和同意、每账号宿主隔离。连接还需要真实 OAuth/OIDC 校验、授权服务、TLS 网关与批准后的同 token 订阅推理验收。未开放无实际能力的连接按钮，也未伪造余额或额度。

生产开放前还须完成原生服务切换与会话绑定、订阅撤销、真实模型档位映射、Codex 下本机语音转写与校对、附件能力预检及目标结束审核联动。现有桥的首次输入协议只支持文字，文件可先解析成选定文本；不接受原音或图片，不会静默切换服务。

完整配置、协议、资格和部署边界见 [Codex 桥说明](../backend/codex-bridge/README.md)。这些外部条件及集成项尚未验收，不能把当前交付描述为已支持 ChatGPT 订阅聊天。

## 已执行验证

| 检查 | 结果及范围 |
| --- | --- |
| Swift 6 严格并发可移植回归 | 40 组通过：队列 7、Codex 协议 5、分析预算和请求 10、方案目标 3、ZIP/XML 文件 4、流程存储 3、草稿 8 |
| Node 桥测试 | 19 个测试通过；Node 源码检查通过 |
| 官方 Codex 实际进程 | initialize/config 冒烟通过；未登录、未推理、未验证订阅额度 |
| Swift 语法 | 41 份修改及新增 Swift 源码使用实际 Swift 6.2.3 编译器解析通过；不是 iOS 类型编译 |
| 工作区格式 | `git diff --check` 通过 |
| 源码静态门禁 | 关闭公开配置检查、允许已有法务占位符时通过；完整门禁仍因缺少本机 Staging 配置等发布前置条件阻断 |

可移植检查编译生产 Foundation 逻辑或明确提取的生产代码，网络流使用测试 fixture，存储加密使用标明的 fixture。ZIP 解压和 XML 解析使用真实实现。没有用 SDK 占位实现声称已编译 SwiftUI、SwiftData、PDFKit、Keychain 或 AES 的 iOS 集成。

重点回归覆盖同会话重复启动、跨作用域排队、撤回后旧加密任务不能恢复敏感数据、继续预算、实际思考回放、完整长文件内容、完整工作流 JSON、超过 64 MiB 请求明确拒绝、缺证据不能标记目标完成。新增 XCTest 源码尚未在 iOS 执行。

复现命令（`SWIFTC` 指向实际 Swift 6.2.3 编译器）：

```sh
python3 tools/check_swift_syntax.py --swiftc "$SWIFTC"
python3 tools/verify_insight_portable.py --swiftc "$SWIFTC"
npm --prefix backend/codex-bridge run check
npm --prefix backend/codex-bridge test
npm --prefix backend/codex-bridge run smoke:codex
VERIFY_PUBLIC_CONFIG=0 VERIFY_ALLOW_LEGAL_PLACEHOLDERS=1 zsh tools/verify_local.sh static
git diff --check
```

## 仍需平台验收

必须在配置齐全的 macOS/Xcode 环境完成 iOS 编译及 XCTest，并按设计逐项检查手机上的列表、键盘、输入框、三档滑块、录音、权限取消、长文件、方案和目标、操作卡、云回执与生命周期。视觉是否与截图一致、真实设备耗时和耗电、PDFKit 扫描文档行为都尚无运行证据。设计中的全部接受标准不能标记为已通过。

改动前备份位于 `/workspace/backups/esheep-ai-before-20261001.tar.gz` 和 `/workspace/backups/esheep-before-20261001.patch`；工作区保留此前称重修复，没有执行发布。
