# 单羊 XLSX 内容与隔离回归（2026-10-22）

## 基线与范围

目标为 TestFlight 3.2 (112) 对应 PR #12 的单羊导出实现。PR #12 合并提交是
`55ae8b0f959e62cd90571487712151a6a6c26740`。本次从
`a9b3d007a1966928d83b99ca0dc7583337fa8ebc` 建立独立分支；已比较确认该提交与
PR #12 合并提交中的 `FarmDataInterchange.swift`、`SheepDetailSnapshotActor.swift`
和 `FarmCapabilities.swift` 无差异。这里验证的是对应导出源码的模拟器执行结果，
不是对已安装 TestFlight 二进制重新做真机验收。

所有新场景使用 `AppSchema.makeContainer(isStoredInMemoryOnly: true)`、虚构牧场和随机 UUID。
测试不连接生产服务、不登录真实账号、不修改任何真实牧场。生成的 XLSX 均保存在测试临时目录，
通过 `Data(contentsOf:)` 重新打开，再调用 `XLSXCodec.decodeSheets` 比较单元格。
XCTest 附件保留实际文件；CI 另用 Python `zipfile` 和 `ElementTree` 解析这些附件，
独立检查 ZIP CRC、OOXML、字面文本及关键内容。没有用另一种生成器代替 App 导出实现。

## 已有覆盖

| 原测试 | 能证明的内容 | 未覆盖的部分 |
| --- | --- | --- |
| `FarmDataInterchangeTests.testSingleSheepWorkbookContainsTimelineFacts` | 字节中出现称重值、健康项目文本 | 工作表结构、完整记录数、历史和跨牧场隔离 |
| `SheepDetailSnapshotActorTests.testDetailSnapshotLoadsTargetRecordsOnceAndIgnoresOtherSheep` | 详情快照含初生重、断奶重及群体健康记录；工作簿非空 | 保存后解析的工作簿是否保留这些事实 |
| `SheepSharePermissionsUITests` | 三角色打开分享及系统保存面板 | 文件内容完整性；本专项不重复运行该 UI 套件 |
| `SettingsVisibilityPolicyTests` | 现有整场导出入口可见性 | 与单羊 readFarm 权限的并列回归 |

## 新增自动化断言

`eSheepNextTests/SingleSheepArchiveTests.swift` 覆盖：

| 场景 | 主要验收 |
| --- | --- |
| 三角色、三牧场、同耳号羊只、离场历史羊 | 13 张表、核心字段、精确日期、数量、记录 ID、牧场 ID、羊只 ID；已离场父母和后代保留 |
| 普通称重、产羔初生重、断奶重、同日两次称重 | 合法事实不遗漏，跨来源重复初生重不重复，增重区间不覆盖原始称重 |
| 历史群体健康记录 | 旧圈舍受治成员在转群后仍保留；重复链接只输出一次；无当前圈舍推断 |
| 异场、异羊、软删除、悬空及冲突关联 | 所有工作表均不包含带 `FORBIDDEN` 标记的排除记录 |
| 公羊配种 | 保留以该公羊为父本的配种；不混入母羊的孕检、产羔和治疗 |
| 删除、缺失及牧场/羊只 ID 不匹配 | 抛出 `sheepNotFound`，不生成工作簿 |
| 混合数组直接调用序列化器 | 推导繁殖资料前先隔离；已删除供体不可作为当前供体读取；合法历史供体快照保留 |
| 跨日与纽约夏令时重叠 | 使用牧场时区；两个不同绝对时刻的同名本地时间保留两条记录 |
| 150 条早期历史、空类别、XML 特殊字符、公式形文本 | 不截断历史；空表保留表头；文本按字面值往返而不执行公式 |
| 单羊/整场权限矩阵 | 单羊 `readFarm` 不隐含整场 `exportFarm`；原有显式授权行为保留 |

## 修复范围

- 日期格式原来依赖设备时区，现在读取牧场时区并在档案中注明。
- 原时间线只使用普通 `WeightRecord`，现在补入详情快照中的初生重和断奶重，同时保留普通称重备注。
- 公羊导出原来仅查 `eweID`，现在另包含其作为父本的配种事实。
- 原来的摘要行会丢失转群前后圈舍、产羔胎次/数量、健康剂量/途径等字段。保留原五张表，
  增加只读明细表，并读取该羊的断奶、离场、备注和用途历史。
- 序列化器先过滤再推导繁殖状态；供体读取也排除软删除记录。
- 健康成员链接不能覆盖另一只羊的明确归属；圈舍名称从同牧场存储重新读取。

混合数组和冲突链接是防御性测试输入，不代表已发现生产牧场存在这些脏数据。
原有 `farmID`/`sheepID`/`deletedAt` 查询隔离及健康成员快照机制继续使用。
没有修改数据模型、云端协议、生产写入流程、`CapabilitySet` 或整场导出入口。
本工作簿用于业务档案查阅，不替代含照片二进制、删除审计和完整云端状态的便携备份。

| 默认角色 | 单羊 readFarm | 整场 exportFarm |
| --- | --- | --- |
| 牧场主 | 允许 | 允许 |
| 管理员 | 允许 | 不允许 |
| 员工 | 允许 | 不允许 |

## 执行证据

- Linux 静态门禁通过：`VERIFY_PUBLIC_CONFIG=0 VERIFY_ALLOW_LEGAL_PLACEHOLDERS=1 ./tools/verify_local.sh static`。
  这是仓库 CI 使用的静态模式，不是发布门禁或真机验收。
- 修复前测试提交：`1841260d35665f7ec68d619914f3504e130e296d`。
  [修复前运行](https://github.com/Jinxed-Liu/esheep/actions/runs/39738228915)。结果待记录。
- 初次修复提交：`2312e425d196bde8ba1615749bf4fbfb6abac8ee`。
  [修复后运行](https://github.com/Jinxed-Liu/esheep/actions/runs/39738816857)。结果待记录。
- 专项工作流：`.github/workflows/single-sheep-archive.yml`，稳定 Xcode 26.6、iPhone 17 Pro 模拟器，
  只选择内容/数据交换/详情快照/权限可见性单元测试，不调用分享面板 UI 测试。

完成前应以对应 SHA 的 XCTest 结果和独立 OOXML 解析结果为准，不能用构建成功、面板打开或工作簿非空代替内容通过。
