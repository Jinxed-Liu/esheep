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

---

# 羊只分享海报 Design QA

## 比较目标

- source visual truth path: `/Users/jinxliu/Desktop/eSheepNext/design-qa-assets/sheep-poster-reference.png`（用户明确确认这是唯一视觉标准）
- implementation screenshot path: `/Users/jinxliu/Desktop/eSheepNext/design-qa-assets/sheep-poster-iphone-air-logo-clipped.png`（横图 Logo 裁切修复前）
- viewport: iPhone Air, native screenshot 1260 × 2736 px（约 420 × 912 pt，3x）
- source pixels: 853 × 1844
- implementation pixels: 1260 × 2736
- CSS size and density normalization: native SwiftUI screen；参考稿为无设备外框的概念图，按完整页面比例及模板卡片局部区域比较，不把系统 Sheet 外框或动态照片内容当作像素偏差
- state: 羊只详情 → 分享菜单 → 分享羊只海报 → 四模板选择页；参考稿使用 E0387 与羊只样片，实现截图使用 131 与真实测试照片

## 比较证据

- full-view comparison evidence: 参考稿与 14:15 iPhone Air 截图已在同一视觉比较输入中打开；当前实现的卡片比例、照片占比和页面信息层级均明显偏离参考稿。
- focused region comparison evidence: 单独检查了顶部说明、横图版照片/信息分界、竖图版全幅照片与标题、系谱三代节点、指标栏、日期页脚、选中边框和底部按钮。

## Evidence and findings

**Findings**

- [P1] 海报比例和整体构图不是参考稿
  Location: 四张模板及导出画布。
  Evidence: 参考稿是狭长宣传海报构图；14:15 实现仍为 3:4 信息卡，照片与下方数据几乎各占一半。
  Impact: 即使局部样式修正，整体仍会显得短、密、像后台信息卡而不是可分享海报。
  Fix: 已统一改为 9:16，逻辑画布 360 × 640，导出 1080 × 1920；缩略图使用相同比例。

- [P1] 横图版下半区层级被通用圆角卡片替代
  Location: 横图深色与浅色模板。
  Evidence: 参考稿在照片下直接形成连续的深蓝/白色信息区，耳号、系谱、指标和日期有明确纵向层级；实现把系谱再次塞进独立圆角面板，内容显得拥挤。
  Impact: 改变了主要区域比例与视觉节奏，是最明显的设计漂移之一。
  Fix: 已把横图照片区提高到 260pt，下半区改为连续表面；移除系谱内层面板，放大耳号和指标值，日期改为居中短线样式。

- [P1] 竖图版没有按参考稿建立全幅照片叙事
  Location: 竖图深色与浅色模板。
  Evidence: 参考稿在全幅照片上依次放置透明 Logo、繁殖角色、蓝色耳号、品种/状态、系谱和底部指标；实现使用通用圆角身份卡片，信息层级与照片融合方式不同。
  Impact: 竖图版失去参考稿最重要的视觉特征。
  Fix: 已改为 360 × 640 全幅照片，加入主题化纵向遮罩；角色、耳号、品种和状态改为左侧直排层级，仅系谱保留半透明浮层。

- [P2] 模板选择页的说明、摘要行和主按钮偏离参考稿
  Location: 模板选择页。
  Evidence: 参考稿居中显示“为 E0387 选择分享样式”并突出蓝色耳号，摘要行使用右侧箭头，主按钮是较紧凑的圆角矩形；旧实现说明靠左、摘要状态与按钮轮廓不同。
  Impact: 页面第一眼的完成度和参考稿不一致。
  Fix: 已居中并单独着色耳号，摘要行改为箭头样式，主按钮改为 56pt 高、14pt 圆角的品牌矩形按钮。

- [P2] 字体、指标和日期格式过小且不符合参考稿
  Location: 四张海报的信息区。
  Evidence: 旧实现耳号、系谱和指标字号偏小，上次产羔日期使用本地斜杠格式，页脚使用左右分散文案；参考稿强调数值并使用点分日期和居中日期装饰线。
  Impact: 缩略图难以扫描，导出图也缺少宣传海报的视觉重点。
  Fix: 已提高耳号、系谱节点和指标字号；日期统一为 `yyyy.MM.dd`，页脚改为居中日期与两侧短线。

- [P1] Logo 区域缺少参考稿的完整品牌构图
  Location: 四张海报左上角。
  Evidence: 参考稿是图形在上、`eSheep+` 与牧场名在下的竖向锁定，并由左上角主题渐变托住；旧实现把图形和文字横排，只在照片上直接叠字。
  Impact: Logo 即使透明，尺寸、轮廓和照片上的视觉重量仍明显不一样。
  Fix: 已改为 38 × 36pt 标志加两行文字的竖向锁定；新增 145 × 120pt 左上角径向渐变，深色版由黑色渐隐托白色 Logo，浅色版由乳白渐隐托蓝色 Logo。

- [P1] 横图 Logo 被照片裁切到画布之外
  Location: 横图深色与浅色模板左上角。
  Evidence: 16:45 iPhone Air 截图中横图仅剩 Logo 右侧极少部分，竖图 Logo 完整；横图照片只固定了 260pt 高度，横向图片按比例放大后的叠加坐标空间宽于 360pt 海报画布。
  Impact: 品牌标识在两个主模板中几乎不可见，属于明显的导出与缩略图破版。
  Fix: 已将横图照片放入明确的 360 × 260pt `ZStack`，先在固定画布内裁切照片，再在同一画布坐标系的左上角叠加完整品牌区域。

- [P1] 系谱节点过散且表面过重
  Location: 四张海报“核心系谱”。
  Evidence: 旧实现祖辈到父母留白约 39pt、父母到本羊约 27pt，并使用较宽、较重的填充节点和额外图标；参考稿两级间距约 18–20pt，节点窄、透明、以细描边和连线为主。
  Impact: 系谱显得松散、笨重，破坏海报的精致感。
  Fix: 已把两级间距固定为横图 18pt、竖图 20pt；祖辈节点宽度降到 20%，父母降到 28%，移除标题图标并显著降低节点填充，仅保留细描边和连接线。

- [P2] 修复后的视觉证据尚未回传
  Location: 四模板选择页与导出海报。
  Evidence: 9:16 与参考稿结构已落入代码，测试目标编译成功；当前没有启动的模拟器，项目也不是预览浏览器支持的 Swift Package，因此没有 post-fix 实现截图。
  Impact: 无法确认 9:16 缩略图在真机上的照片裁切、文字可读性、滚动长度及底部按钮遮挡情况。
  Fix: 在 iPhone Air 重新运行当前版本，回传同页面截图，再按相同视口复核。

## 必查表面

| 表面 | 当前处理 | 仍需真机确认 |
| --- | --- | --- |
| 字体与层级 | 横图耳号 31pt、竖图耳号 32pt；角色/品种/状态分层 | 缩略状态的小字锐度与长耳号缩放 |
| 间距与布局 | 9:16；横图上下分区、竖图全幅照片、三代系谱固定轨道 | 两行模板在 iPhone Air 的滚动节奏与按钮遮挡 |
| 颜色与令牌 | 深蓝/白/品牌蓝；竖图使用主题遮罩和身份条 | 浅色版在真实高亮照片上的对比度 |
| 图像与资产 | 使用真实羊只照片；Logo 为官方线稿透明 PNG | 真实照片横竖裁切的主体位置 |
| 文案与内容 | “分享内容 / 系谱与繁殖信息”、点分日期、真实繁殖指标 | 较长品种名与未知系谱状态 |

**Open Questions**

- 9:16 后实际羊只照片的主体裁切，以及较长耳号、品种文字是否拥挤，仍需由修复后的运行截图确认。

**Implementation Checklist**

- 在 iPhone Air 捕获 9:16 模板选择页。
- 检查横图照片高度、连续信息区及竖图全幅照片层级。
- 检查祖辈、父母、本羊三条轨道及系谱与指标条间距。
- 捕获四种 1080 × 1920 导出海报和系统分享入口；修复剩余 P0/P1/P2 后再次比较。

**Follow-up Polish**

- 在实际照片上复核深色版的底部文字对比度。

## Comparison history

- Iteration 0: source visual opened; implementation capture blocked before the first visual comparison. Build and test-target compilation are not treated as visual evidence.
- Iteration 1: 将参考稿和用户提供的 iPhone Air 实现截图放入同一视觉比较输入；发现 P1 Logo 方底未抠除、P1 系谱本羊节点越界重叠。
- Iteration 1 fixes: 新增官方线稿透明资产 `PosterBrandMark` 并移除品牌底板；系谱改为三条固定轨道，连线在节点边界终止；新增轨道边界和透明资产回归测试。
- Iteration 2: 14:15 iPhone Air 截图确认 Logo 与系谱重叠已改善，但用户指出整体仍与最初参考稿差距过大，且明确要求改为 9:16。
- Iteration 2 fixes: 统一 9:16 / 1080 × 1920；横图版改为照片加连续信息区；竖图版改为全幅照片叙事；同步重做标题、系谱表面、指标、日期、选择页摘要和按钮。
- Iteration 3: 用户指出 Logo 尺寸/区域仍未复刻参考图，并明确指出 Logo 区域有渐变；同时认为系谱造型过丑。
- Iteration 3 fixes: 品牌区改为竖向锁定和主题径向渐变；系谱代际间距压缩到 18–20pt、节点减宽减重、移除标题图标；横图照片区调整到 260pt，让 9:16 增量更多留给真实照片。
- Iteration 4: 16:45 iPhone Air 截图显示竖图 Logo 完整，但两个横图 Logo 被照片自身的宽布局坐标裁到画布左侧之外。
- Iteration 4 fixes: 横图照片与品牌区改为同一个固定 360 × 260pt `ZStack`，照片仅在内部裁切，Logo 坐标不再受源照片宽高比影响。
- Iteration 5: App 与测试目标编译成功；尚无裁切修复后的真机截图，不能把编译结果作为 post-fix visual evidence，继续 blocked。

## Final result

final result: blocked
