# Notes（iPad 手写笔记）

一个面向 iPad 和 Apple Pencil 的原生手写笔记应用。项目使用 SwiftUI + PencilKit，零第三方依赖，默认只在应用本地沙盒中保存笔记。

> 当前开发包仍使用临时显示名“墨记”，仅供个人侧载验证。公开测试或上架前必须更换正式名称并完成商标、应用商店与公开市场检索。

## 当前功能

- 多笔记本、多页面管理，支持新建、重命名和删除。
- Apple Pencil 低延迟书写，也可切换为手指书写。
- 使用 iPadOS 原生 PencilKit 工具栏：钢笔、铅笔、马克笔、橡皮、套索、颜色和粗细。
- 当前页面撤销、重做和清空。
- 空白纸、横线纸、方格纸三种背景。
- 笔迹自动保存；切页和进入后台时强制落盘。
- 元数据与每页笔迹分开原子保存；无法解析的元数据不会被静默覆盖。
- 数据异常时进入显式只读保护并禁用画布，避免“看似写入、实际丢失”。
- 手动导出单文件完整备份，包含目录与全部 PencilKit 笔迹。
- 备份包含整包和逐页 SHA-256 完整性校验，并限制文件、目录、页面与标题大小。
- 导入前验证全部结构和笔迹；恢复时生成全新标识并追加副本，不覆盖现有笔记。
- 可通过 iPadOS 系统“文件”位置或分享面板，把备份交给用户选择的网盘应用。
- 无账号、无自动网络请求、无分析 SDK、无后台云端上传。

## 运行要求

- iPadOS 17.0 或更高版本。
- Xcode 16 或更新的稳定版本（本次仅在本机 Xcode 27 beta 上完成编译门禁）。
- 推荐使用 Apple Pencil；没有 Pencil 时可点击工具栏的输入方式按钮开启手指书写。

## 在 iPad 上运行

1. 用 Xcode 打开 `InkNotes.xcodeproj`。
2. 选择 `InkNotes` target，在 Signing & Capabilities 中选择你自己的开发团队。
3. 连接已开启开发者模式并信任此 Mac 的 iPad。
4. 选择该 iPad，点击 Run。

开发包显示名称暂为“墨记”，Bundle Identifier 为 `com.salomeailin.InkNotes`。Bundle Identifier 暂时保持不变，以免覆盖安装时丢失现有沙盒数据；正式显示名称另行确定。

## 验证命令

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift test

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild \
  -project InkNotes.xcodeproj \
  -scheme InkNotes \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

`swift test` 当前包含 22 个测试，覆盖元数据/笔迹往返、损坏数据不覆盖、切页保存时序、备份编解码、摘要与长度/内存读取上限、标题边界、非法 PencilKit 数据拒绝，以及恢复副本不覆盖原笔记。Xcode 构建命令验证完整 iPadOS 应用可以编译和链接。

## 本地数据

数据位于应用沙盒的 `Application Support/InkNotes`：

```text
InkNotes/
├── library.json
└── Drawings/
    └── <page-uuid>.drawing
```

删除笔记本或页面后，当前版本会保留对应的孤立笔迹文件，避免立即破坏数据；暂未提供“最近删除”恢复界面。

## 备份与网盘

- 备份文件扩展名为 `.notesbackup`，首版上限为 32 MiB；单页笔迹上限为 8 MiB。
- 备份当前不加密，可能包含私密手写内容；仅应保存到用户信任的位置。
- 导出与导入完全由用户主动触发。若百度网盘 HD 在系统“文件”或分享面板中提供入口，可直接选择它保存备份。
- 当前不是百度账号直连或双向同步，也不会在应用或仓库中保存百度 `SecretKey`、访问令牌或刷新令牌。

## 已知边界

- 当前 Mac 没有安装 iOS Simulator runtime，因此本次已完成源码检查、核心测试和 generic iOS 构建，尚未做模拟器启动。
- iPadOS 27 真机已完成签名构建与安装；首次启动仍需在设备上完成个人开发者证书信任后复验。
- 尚未完成 Apple Pencil 的压感、倾斜、掌触防误触、旋转、分屏，以及百度网盘“文件位置/分享扩展”两条路径的真机验收。
- 暂无 iCloud 同步、PDF 导入/导出、文本识别、搜索、自定义应用图标和 App Store 配置。
- MVP 明确关闭多窗口，避免两个画布同时编辑同一页造成覆盖；后续如需 Stage Manager 多窗口，应先实现文件协调或笔迹合并。
- 仓库尚未选择开源许可证；在复制、再分发或接受外部贡献前应先确定许可证。

## 调研说明

GitHub 上已有 Jottre、Cecilia's Notes、Saber 等同类项目。本项目没有复制其源码，而是基于 Apple 官方 PencilKit API 独立实现，以避免 GPL/AGPL 或不明确许可证带来的复用边界。
