# 分析页重心调整 — 2026-09-16

## 用户目标
截图反馈“页面的整体重心”不合理。分析功能应成为主体，AI 是辅助入口。

## 修改
- 使用现有 SettingsCard / SettingsNavigationRow，把增重、羔羊、繁殖、采食统一为顶部单列生产分析入口。
- 每个入口明确说明分析内容，保留原有目标页面。
- AI 放到下方“AI 辅助查询”分区，保留一个对话入口。
- 移除入口页的三条推荐问题、“今天的牧场”、快照及最近记录日期。
- 保留数据加载、下拉刷新与错误提示，错误状态增加重新加载按钮。

## 验证
- iOS Debug 真机目标编译成功；未安装到真实设备。
- iPhone 18 Pro / iOS 27 模拟器 Debug 编译成功、安装成功。
- 隔离设计验收牧场启动成功，停留首页。
- Mac 锁定且自动解锁失败，自动点击未切换到分析页；入口跳转、正常字号及大字号视觉验收未完成。
- 与本次备份逐段比较，分析详情实现一致。
- git diff --check 通过。

## 文件与证据
- 代码：eSheepNext/Features/Workspace/FarmAnalysisCenterView.swift
- 备份：backups/20260916-004141-analysis-page-focus/FarmAnalysisCenterView.swift
- 真机目标构建日志：/Volumes/移动硬盘/eSheepNext-Dev/Logs/analysis-page-focus-build.log
- 模拟器构建日志：/Volumes/移动硬盘/eSheepNext-Dev/Logs/analysis-page-focus-simulator.log

## 后续：安装到 iPhone 16 Pro
用户随后指定安装到 16 Pro。已核对物理设备 iPhone 16 Pro（00008140-000164E22062201C），使用本次已通过编译的 com.sheepfarm.next.dev 3.1.1 (24)。codesign 严格校验通过，devicectl 覆盖安装与正常启动均成功。未执行卸载或数据清除。此次证据为安装与启动，不代表页面真机视觉验收完成。

- 安装记录：/Volumes/移动硬盘/eSheepNext-Dev/Logs/analysis-page-focus-16pro-install.json
- 启动记录：/Volumes/移动硬盘/eSheepNext-Dev/Logs/analysis-page-focus-16pro-launch.json
