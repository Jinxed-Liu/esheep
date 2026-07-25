# 洞察聊天页 Design QA

## 视觉依据

- iMessage 布局参考：`/Users/jinxliu/Desktop/Screenshot iPhone Air 2026-07-24 at 21.51.57.png`
- 键盘重叠问题：`/Users/jinxliu/Downloads/截屏 2026-07-24 22.48.26.png`
- 当前真机静态截图：`/Users/jinxliu/Desktop/eSheepNext/design-qa-assets/insight-chat-iphone-air-v6.png`
- 并排对比：`/Users/jinxliu/Desktop/eSheepNext/design-qa-assets/insight-chat-reference-vs-v6.png`
- 视口：iPhone Air，1260 × 2736，iOS 27.0

## 检查结果

| 检查项 | 状态 | 证据或处理 |
| --- | --- | --- |
| iMessage 顶部信息区 | 通过 | 头像、名称胶囊、返回与菜单采用紧凑居中布局 |
| 底部工具栏长度与静态位置 | 通过 | 真机截图与参考图并排检查 |
| 加号菜单 | 通过 | 真机操作已弹出相册、拍照、建议问题菜单 |
| 输入框焦点 | 通过 | 真机操作出现输入光标；Device Hub 连接时系统按外接键盘处理 |
| 键盘与工具栏间距 | 待用户复验 | 已移除聚焦态负间距，键盘展开时额外上移 14pt，并重新安装到真机 |
| 屏幕中部右滑返回 | 通过 | 从页面中部横向拖动后返回洞察分析页 |
| 录音响应 | 待用户复验 | 录音不再受 MiMo 可用状态限制；电平刷新从 60ms 降到 100ms，并隔离局部重绘 |

## 构建证据

- iPhone Air Debug 构建成功并安装、启动。
- iOS 模拟器 `build-for-testing` 成功。
- 构建成功只证明代码可构建；键盘间距和录音手感仍以真机操作为最终验收。
