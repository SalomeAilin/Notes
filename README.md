# InkNotes Dev（内部开发包）

一个面向 iPad 和 Apple Pencil 的原生手写笔记应用。项目使用 SwiftUI + PencilKit，零第三方依赖，笔记只保存在应用本地沙盒中。

> `InkNotes Dev` 只是个人侧载验证使用的内部占位名，不是正式品牌。公开测试或上架前仍须确定正式名称并完成商标、App Store 与公开市场核查。

## 当前功能

- 多笔记本、多页面管理，支持新建、重命名和删除。
- Apple Pencil 低延迟书写，也可切换为手指书写。
- 使用 iPadOS 原生 PencilKit 工具栏：钢笔、铅笔、马克笔、橡皮、套索、颜色和粗细。
- 当前页面撤销、重做和清空。
- 空白纸、横线纸、方格纸三种背景。
- 笔迹自动保存；切页和进入后台时强制落盘。
- 元数据与每页笔迹分开原子保存；无法解析的元数据不会被静默覆盖。
- 数据异常时进入显式只读保护并禁用画布，避免“看似写入、实际丢失”。
- 无账号、无网络请求、无分析 SDK、无云端上传。

## 运行要求

- iPadOS 17.0 或更高版本。
- Xcode 16 或更新的稳定版本（本次仅在本机 Xcode 27 beta 上完成编译门禁）。
- 推荐使用 Apple Pencil；没有 Pencil 时可点击工具栏的输入方式按钮开启手指书写。

## 在 iPad 上运行

1. 用 Xcode 打开 `InkNotes.xcodeproj`。
2. 选择 `InkNotes` target，在 Signing & Capabilities 中选择你自己的开发团队。
3. 连接已开启开发者模式并信任此 Mac 的 iPad。
4. 选择该 iPad，点击 Run。

开发包显示名称为 `InkNotes Dev`。在同一签名团队和兼容 application identifier 下，Bundle Identifier 保持为 `com.salomeailin.InkNotes`，以便覆盖安装时继续访问同一应用沙盒。正式更名只修改展示层；现有安装不得随意更换签名身份、Bundle Identifier 或本地数据目录。

## 验证命令

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  ./scripts/verify-brand-neutralization.sh
```

门禁运行 8 个测试，并分别构建 Debug、Release 两套 generic iOS 产物。源码、有效构建设置和最终 `InkNotes.app` 都必须使用内部显示名 `InkNotes Dev`、稳定 Bundle Identifier、iPad-only 与最低 iPadOS 17.0；退役名称扫描器以三种编码负控自检，并检查发货源码与两套构建产物。

## 本地数据

数据位于应用沙盒的 `Application Support/InkNotes`：

```text
InkNotes/
├── library.json
└── Drawings/
    └── <page-uuid>.drawing
```

删除笔记本或页面后，当前版本会保留对应的孤立笔迹文件，避免立即破坏数据；暂未提供“最近删除”恢复界面。

## 更名兼容边界

正式名称确定后，首轮只修改 `CFBundleDisplayName`、界面文案、图标和商店资料。为保留已有安装与笔记，以下技术身份保持不变：

- Bundle Identifier：`com.salomeailin.InkNotes`
- 本地目录：`Application Support/InkNotes`
- Xcode target、scheme、Swift 模块和工程目录中的 `InkNotes` 技术名称

## 已知边界

- 当前 Mac 没有安装 iOS Simulator runtime，因此本次已完成源码检查、核心测试和 generic iOS 构建，尚未做模拟器启动。
- 尚未完成真机 iPad + Apple Pencil 的压感、倾斜、掌触防误触、旋转和分屏验收。
- 暂无 iCloud 同步、PDF 导入/导出、文本识别、搜索、自定义应用图标和 App Store 配置。
- MVP 明确关闭多窗口，避免两个画布同时编辑同一页造成覆盖；后续如需 Stage Manager 多窗口，应先实现文件协调或笔迹合并。
- 仓库尚未选择开源许可证；在复制、再分发或接受外部贡献前应先确定许可证。

## 调研说明

GitHub 上已有 Jottre、Cecilia's Notes、Saber 等同类项目。本项目没有复制其源码，而是基于 Apple 官方 PencilKit API 独立实现，以避免 GPL/AGPL 或不明确许可证带来的复用边界。
