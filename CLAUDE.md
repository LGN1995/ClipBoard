# ClipBoard - macOS 剪切板工具

## 项目概述

一个纯净的 macOS 菜单栏剪切板工具，功能简单：
- 全局快捷键 `⌘⇧V` 唤起
- 历史从屏幕底部弹出
- 左右滑动切换历史
- 点击自动复制并粘贴

## 技术栈

- **语言**：Swift / SwiftUI
- **架构**：菜单栏插件（LSUIElement，无 Dock 图标）
- **面板**：NSPanel（透明浮动，从底部弹出）
- **存储**：UserDefaults（保留最近 50 条）
- **快捷键**：CGEvent tap 全局监听
- **Xcode 项目**：XcodeGen

## 设计规范

参考 **UI UX Pro Max** 设计理念（67种风格、161套配色）：

### 风格定位
- **简约实用主义**：不追求花哨，保持功能纯粹
- **系统融合**：贴合 macOS 原生视觉风格
- **无干扰**：面板随用随开，用完即走

### 配色
- 使用 macOS 系统颜色（NSColor.controlBackgroundColor 等）
- 深色/浅色模式自适应
- 不自定义主题色，保持与系统一致

### 字体
- 系统字体 SF Pro
- 标题：16pt semibold
- 正文：14pt regular
- 时间戳：12pt caption（secondary 色）

### 间距
- 面板高度：200pt
- 卡片宽度：300pt
- 卡片间距：12pt
- 卡片内边距：12pt
- 圆角：12pt

### 动效
- 面板出现：alpha 0→1，duration 0.2s
- 面板消失：alpha 1→0，duration 0.2s

### 交互
- 点击历史项：复制到剪贴板 + 模拟 ⌘V 粘贴
- 点击 × ：删除该条历史
- 点击关闭按钮：隐藏面板
- 全局 ⌘⇧V：切换面板显示/隐藏

## 文件结构

```
ClipBoard/
├── App/
│   ├── main.swift           # 入口
│   └── AppDelegate.swift   # 菜单栏 + 全局快捷键
├── Clipboard/
│   ├── ClipboardManager.swift    # 监听 + 存储
│   └── ClipboardItem.swift       # 数据模型
├── UI/
│   ├── ClipboardPanel.swift      # 底部弹出面板
│   └── ClipboardItemView.swift   # 单条记录视图
├── Resources/
│   └── Info.plist
└── project.yml
```

## 注意事项

- 面板使用 NSPanel，styleMask 为 `.nonactivatingPanel`
- collectionBehavior 需要包含 `.canJoinAllSpaces`
- 模拟粘贴使用 CGEvent，需要 Accessibility 权限提示
- LSUIElement 设为 true，无 Dock 图标
- 面板不获取焦点，避免影响其他应用输入