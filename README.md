# Notes（iPad 手写笔记）

一个面向 iPad 和 Apple Pencil 的原生手写笔记应用。项目使用 SwiftUI + PencilKit，零第三方依赖，默认只在应用本地沙盒中保存笔记。

> 当前开发包使用内部占位显示名 `InkNotes Dev`，仅供个人侧载验证。已确认高碰撞的“墨记”不再进入可构建产品；`InkNotes Dev` 也不是正式品牌。公开测试或上架前必须选定正式名称，并完成商标、应用商店与公开市场检索。

## 当前功能

- 多笔记本、多页面管理，支持新建、重命名和删除。
- Apple Pencil 低延迟书写，也可切换为手指书写。
- 使用 iPadOS 原生 PencilKit 工具栏：钢笔、铅笔、马克笔、橡皮、套索、颜色和粗细。
- 当前页面撤销、重做和清空。
- 空白纸、横线纸、方格纸三种背景。
- 笔迹自动保存；切页和进入后台时强制落盘。
- 元数据与每页笔迹分开耐久原子保存；无法解析的元数据不会被静默覆盖。
- 数据异常时进入显式只读保护并禁用画布，避免“看似写入、实际丢失”。
- 手动导出单文件完整备份，包含目录与全部 PencilKit 笔迹。
- 备份包含整包和逐页 SHA-256 完整性校验，并限制文件、目录、页面与标题大小。
- 导入前验证全部结构和笔迹；恢复时生成全新标识并追加副本，不覆盖现有笔记。
- 恢复计划会先写入本地不可变事务记录；同一备份重复导入时不再追加第二份，未完成写入可按原映射续完。目录已提交但计划内笔迹缺失时，只补回缺失文件，已有笔迹（包括导入后的用户编辑）不会被覆盖。
- 可通过 iPadOS 系统“文件”位置或分享面板，把备份交给用户选择的网盘应用。
- 无账号、无自动网络请求、无分析 SDK、无后台云端上传。

## 运行要求

- iPadOS 17.0 或更高版本。
- Xcode 16 或更新的稳定版本（本次仅在本机 Xcode 27 beta 上完成编译门禁）。
- 推荐使用 Apple Pencil；没有 Pencil 时可点击工具栏的输入方式按钮开启手指书写。

## 在 iPad 上运行

1. 用 Xcode 打开 `InkNotes.xcodeproj`，在 Apple Accounts 中登录并下载已有开发描述文件。
2. 保持项目中的 `DEVELOPMENT_TEAM` 为空，不把个人 Team ID 写入 Git。
3. 连接已开启开发者模式并信任此 Mac 的 iPad。
4. 先按下方命令生成签名包并通过只读真机预检，再执行安装。

开发包显示名称暂为 `InkNotes Dev`，Bundle Identifier 为 `com.salomeailin.InkNotes`。这个名称只标识内部开发包，不代表正式品牌；Bundle Identifier 保持不变，以免覆盖安装时丢失现有沙盒数据。

### 真机签名与预检

```bash
# 只使用本机已有、仍有效且匹配 Bundle Identifier 的开发描述文件生成签名包
./scripts/build-signed-ipad-app.sh

# 对现有签名包做只读检查；设备恢复连接后再加精确设备名
./scripts/verify-ipad-readiness.sh \
  --app DerivedData/device-<commit>-build-3.<run>/Build/Products/Debug-iphoneos/InkNotes.app \
  --provenance DerivedData/device-<commit>-build-3.<run>/provenance.json \
  --device-name Alsay_ipad
```

构建脚本要求工作树干净，并把签名产物绑定到当前精确 Git commit；它不会把 Team ID 写入项目，也不会调用自动更新描述文件或自动注册设备。`provenance.json` 记录 commit、版本、SDK/Xcode、签名 CDHash 和关键文件 SHA-256，但不记录 Team ID、设备标识、描述文件 UUID 或访问凭据。描述文件不足 14 天时会明确警告；过期或不匹配时直接失败。

预检脚本只读取产物、描述文件和指定设备状态，不安装、不启动、不卸载应用，也不会改动设备。必须使用目标 iPad 的精确名称；目标设备不可用时停止，不改装到其他设备。

## 验证命令

```bash
./scripts/verify-compatibility.sh
```

门禁先执行全仓 Swift strict format lint，再运行 127 个测试，并分别构建 Debug、Release 两套 generic iOS 产物。源码和两套构建产物都必须使用内部占位显示名 `InkNotes Dev`；产品源码与构建产物还会扫描 UTF-8/UTF-16 资源，防止本地化文件重新带回已撤下的名称，同时保持稳定技术身份不变。除原有的元数据/笔迹往返、损坏数据保护、切页保存时序、备份编解码、边界限制和恢复副本测试外，还会验证系统无法提供 Application Support 时不会静默写入临时目录，而是让仓库读写失败并使应用进入只读保护；本地耐久门禁覆盖唯一临时文件、严格残留清理、文件与父目录同步顺序、跨仓储实例排他发布、WAL 数量原子限制、首次目录补同步、热路径不重复准备，以及结果不确定后的 WAL、孤立笔迹、既有恢复笔迹和目录回读重同步。恢复门禁覆盖提交后重试不重复追加、同 ID 异内容冲突、部分导入失败关闭、相同孤立笔迹复用、不同孤立笔迹不覆盖、目录完整但笔迹缺失时安全补回、当前选中缺失页的 Store 重试、已有用户编辑与主动清空不被覆盖，以及重复操作不改变当前画布。门禁也验证异常内存笔迹不能在备份或恢复的持久化屏障前覆盖有效磁盘文件，同时保证有效的最新笔画会在无关页面导致全库校验失败前落盘。提交到 Git 的 v1 历史备份与真实 PencilKit 单笔画用于检查完整性、恢复、标识重映射和落盘链路。百度网盘上传门禁覆盖官方 Go SDK 流程字段、`return_type` 分支、4 MiB 分片、分片与最终 MD5 校验、流式响应上限、拒绝重定向、真实 URLSession Task 取消及凭据脱敏；还覆盖上传单飞、绑定操作标识的取消、严格进度状态机、任何 HTTP 前持久化、跨仓储实例原子 admission、取消/清理竞态、重启后的安装级屏障、内容身份冲突、秒传/结果未知对账门禁和安全进度快照。OAuth 临时隔离门禁会拒绝常见客户端密钥标记/配置、百度授权控制面地址、占位 broker、提前引入的授权 UI、回调/后台能力及任何从 App、View、Store 发起的百度直连；同时核对 iPad-only、最低 iOS 17.0、Bundle Identifier 及备份文件身份。

## 本地数据

数据位于应用沙盒的 `Application Support/InkNotes`：

```text
InkNotes/
├── .UploadReconciliation.lock
├── .inknotes-durable-write.lock
├── library.json
├── Drawings/
│   ├── .inknotes-durable-write.lock
│   └── <page-uuid>.drawing
├── RestoreTransactions/
│   ├── .inknotes-durable-write.lock
│   └── <backup-uuid>.json
└── UploadReconciliation/
    └── <backup-uuid>.json
```

`.inknotes-durable-write.lock` 是同目录写入协调文件，不属于用户笔记或备份内容。应用首次使用各目录时会把目录权限收紧为 `0700`，新写入或重新确认的持久化文件使用 `0600`，并清理仅符合应用 UUID 命名规则的崩溃残留临时文件；其他 `.tmp` 文件不会被删除。`RestoreTransactions` 是本机恢复操作的不可变 WAL/回执，不写入 `.notesbackup`，并限制为最多 1,000 份、单份 2 MiB。`UploadReconciliation` 是未接 UI 的百度上传安装级不可变尝试屏障，单份最多 16 KiB、总计最多 1,000 份；记录只含尝试/备份标识、完整归档 SHA-256、MD5、大小和规范远端路径，不含访问凭据、`uploadid`、请求 URL 或响应体。删除笔记本或页面后，当前版本会保留对应的孤立笔迹文件，避免立即破坏数据；暂未提供“最近删除”恢复界面。

## 更名兼容边界

`InkNotes Dev` 只是内部开发占位名。正式更名只应修改展示层，例如 `CFBundleDisplayName`、界面文字和备份类型说明。以下技术身份已经被兼容门禁固定，不能随品牌名称修改：

- Bundle Identifier：`com.salomeailin.InkNotes`
- 本地目录和文件：`InkNotes/library.json`、`InkNotes/Drawings/*.drawing`、`InkNotes/RestoreTransactions/*.json`、`InkNotes/UploadReconciliation/*.json`
- 备份 UTI、扩展名和 MIME：`com.salomeailin.notes.backup`、`.notesbackup`、`application/vnd.salomeailin.notes-backup`
- 备份 magic/格式版本与本地 schema 版本

若未来确实需要修改任一稳定身份，必须先设计显式迁移，并用旧真机数据和已提交的 v1 黄金备份验收。

## 备份与网盘

- 备份文件扩展名为 `.notesbackup`，首版上限为 32 MiB；单页笔迹上限为 8 MiB。
- 备份当前不加密，可能包含私密手写内容；仅应保存到用户信任的位置。
- 导出与导入完全由用户主动触发。若百度网盘 HD 在系统“文件”或分享面板中提供入口，可直接选择它保存备份。
- 代码内部已具备未接入界面的百度网盘 REST 备份上传核心：上传前校验归档，按 4 MiB 分片，并使用固定 HTTPS 分片端点校验分片 MD5 和常规创建结果。
- 上传协调器同一时刻只允许一个任务；取消绑定具体操作标识，迟到的旧取消不能误伤下一单。启动上传 worker、许可任何 HTTP 请求前，协调器会先写入安装级不可变尝试记录；写入失败、记录损坏或同一备份内容身份冲突时不会启动网络工作。
- 只有能够证明尚未许可 `precreate` 请求的失败或取消，才由原尝试按完整身份精确删除记录并允许安全重试。一旦许可 `precreate`，取消、超时、服务端错误、畸形响应、秒传和成功结果都保留记录；应用重启、换一个短期 token 或另一个共享同一持久化容器的协调器都会在任何网络请求前停止同一备份的重复上传。
- 已严格匹配路径、大小、MD5 和备份标识的常规创建结果仍会向当前调用方返回“已验证成功”；这里的持久化记录是保守的 at-most-once 尝试屏障，不等于已经完成账号级远端对账。
- 上传数据面仅与百度官方 Go SDK 的 `precreate → upload → create` 字段和分支做离线对齐；`return_type=2` 只返回“秒传信号 + 本地请求摘要”，不伪造远端文件标识或已对账元数据；`return_type=1` 若没有待上传分片则按畸形响应失败关闭，不发送无效创建请求。
- 路径冲突参数固定为 `rtype=0`，不自动重命名、不覆盖；冲突保留为服务端 API 错误，待真实账号联调时再做幂等对账。
- 上传核心仅接收运行时短期访问凭据和应用目录，不负责登录、换取或刷新凭据，也不持久化凭据；备份内容由 iPad 直接发送到百度网盘接口。
- 当前屏障没有百度账号作用域，也不从 token 或 token 哈希派生账号标识；尚无同账号远端查询、自动核销、TTL 或“强制清除”入口。只有真实 OAuth broker 提供稳定的非秘密账号绑定标识并完成正向远端核验后，才能设计安全核销。
- 当前仍不是可供用户操作的百度账号直连或双向同步；没有正式应用名称、OAuth broker 和真实授权前，不展示“已连接”状态或上传按钮。

### 百度授权安全边界

- 百度官方 SDK 当前的[授权码换 token](https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/auth_code2token.go)与[设备码换 token](https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/auth_device_token.go)都要求 `client_secret`；现有公开资料尚未确认可供 iOS public client 使用的 PKCE 流程。因此应用包、Info.plist、xcconfig、构建设置和 Keychain 都不得携带该密钥，iPad 端也不得直接执行换 token 或刷新。
- 未来允许的生产路径是：用 `ASWebAuthenticationSession` 打开真实 HTTPS OAuth broker；百度授权回调进入 broker；broker 只向应用回传短时、高熵、单次使用的 ticket，不在回调 URL 中携带 access token 或 refresh token；应用再通过同一 broker 的 HTTPS 接口兑换并验证凭据。
- 取消、ticket 过期或重放、`state` 不匹配、回调来源不匹配、broker 响应无法验证时都必须失败关闭。真实 broker origin、正式回调身份、兑换协议、部署、用户身份绑定和真实账号门禁尚未确定，所以当前没有 URL Scheme、授权 UI、Keychain 凭据模型或“已连接”状态。

## 已知边界

- 当前 Mac 没有安装 iOS Simulator runtime，因此本次已完成源码检查、核心测试和 generic iOS 构建，尚未做模拟器启动。
- 本地目录、元数据、笔迹与恢复 WAL 已请求“临时文件写入 → 文件 `fsync` → 原子发布 → 父目录 `fsync`”，并覆盖发布结果不确定后的重同步；主机故障注入只证明代码请求顺序，尚未在 iPadOS 27 真机做硬断电实验，不能宣称控制器级绝对掉电耐久。若只删除同批导入内容的一部分，重复导入会失败关闭；删除整批后可由用户再次显式恢复。
- 升级前已经导入、但本机没有对应 `RestoreTransactions` 回执的历史备份，无法被可靠追认为旧导入；再次导入仍会按新副本处理。
- 恢复 WAL 的数量检查与不可变发布位于同一协调区，使用进程内目录标识锁、POSIX 文件锁与 `RENAME_EXCL`；这只保证遵守同一协议的沙盒写入者。当前没有 App Group 或扩展进程真机验收，未来引入扩展前仍需补文件协调与多进程故障测试。
- 当前精确 HEAD 已生成 `0.2.0 (3)`、iPad-only、arm64 的开发签名包及脱敏来源清单；目标设备已确认是 iPadOS 27.0，但连接通道仍不可用。因此本轮只证明构建、签名和静态兼容预检通过，尚未安装、启动，也未验证覆盖安装后的旧沙盒数据。
- 尚未完成 Apple Pencil 的压感、倾斜、掌触防误触、旋转、分屏，以及百度网盘“文件位置/分享扩展”两条路径的真机验收。
- 百度网盘上传核心目前只完成可重复的官方 Go SDK 离线对齐门禁；真实账号门禁未通过，尚未验证服务端字段、路径冲突对账、配额、授权目录或 iPadOS 27 前后台传输行为。
- 百度上传记录使用进程内锁、POSIX 跨进程文件锁、不覆盖原子发布以及文件/目录 `fsync`；尚未在 iPad 上做拔电式硬断电验证，也没有 App Group 容器，因此不能宣称跨扩展共享或绝对掉电耐久。记录会保守累积到 1,000 份上限，当前没有自动清理或用户解锁界面。
- 持久化屏障已经阻止同一容器内的重启盲重试，但没有稳定的百度账号绑定和远端查询，仍未完成“远端存在/不存在”的账号级对账。当前没有后台传输能力，进入后台只允许协作式取消，不能承诺继续上传。
- 暂无 iCloud 同步、PDF 导入/导出、文本识别、搜索、自定义应用图标和 App Store 配置。
- MVP 明确关闭多窗口，避免两个画布同时编辑同一页造成覆盖；后续如需 Stage Manager 多窗口，应先实现文件协调或笔迹合并。
- 仓库尚未选择开源许可证；在复制、再分发或接受外部贡献前应先确定许可证。

### iPadOS 27 真机验收清单

- 安装前先导出一份可回读备份；不得卸载旧包，覆盖安装后确认原沙盒笔记仍在。
- 首次冷启动、强制退出后重启、进入后台再恢复、快速切页后，检查目录、笔迹和当前页均正确落盘。
- 用 Apple Pencil 验证低延迟书写、压感、倾斜、掌触防误触；再验证手指书写开关、橡皮、套索、撤销、重做和清空。
- 验证横竖屏旋转、分屏和尺寸变化期间画布不丢笔、不偏移、不错误覆盖其他页面。
- 导出 `.notesbackup`，在保留原数据的前提下导入副本；检查完整性失败关闭、重复导入不重复追加和已有笔迹不被覆盖。
- 分别验证百度网盘 HD 作为系统“文件”位置和分享扩展的手动导出路径；未完成真实 OAuth 前不得宣称账号直连。
- 硬断电/强制掉电属于破坏性故障测试，必须另行明确授权并先做可恢复备份，本清单不默认执行。

## 调研说明

GitHub 上已有 Jottre、Cecilia's Notes、Saber 等同类项目。本项目没有复制其源码，而是基于 Apple 官方 PencilKit API 独立实现，以避免 GPL/AGPL 或不明确许可证带来的复用边界。
