import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let notesBackup = UTType(
    exportedAs: BackupArchiveCodec.uniformTypeIdentifier,
    conformingTo: .data
  )
}

private struct BackupTransferItem: Transferable, Sendable {
  let data: Data
  let filename: String

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .notesBackup) { item in
      item.data
    }
    .suggestedFileName { item in
      item.filename
    }
  }
}

private struct PreparedBackup: Sendable {
  let item: BackupTransferItem
  let createdAt: Date
  let notebookCount: Int
  let pageCount: Int
}

private struct PendingBackupImport: Sendable {
  let data: Data
  let filename: String
  let preview: BackupArchivePreview
}

private struct BackupTransferNotice: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

private func formatBackupByteCount(_ count: Int) -> String {
  ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}

private enum BackupTransferViewError: LocalizedError {
  case fileIsNotRegular
  case fileTooLarge(actual: Int, maximum: Int)

  var errorDescription: String? {
    switch self {
    case .fileIsNotRegular:
      "请选择一个普通的笔记备份文件。"
    case .fileTooLarge(_, let maximum):
      "备份文件超过 \(formatBackupByteCount(maximum)) 的安全上限。"
    }
  }
}

private enum BackupFileReader {
  static let maximumByteCount = BackupArchiveLimits.maximumArchiveByteCount
  private static let chunkByteCount = 1024 * 1024

  static func read(from url: URL) async throws -> Data {
    try await Task.detached(priority: .userInitiated) {
      let isSecurityScoped = url.startAccessingSecurityScopedResource()
      defer {
        if isSecurityScoped {
          url.stopAccessingSecurityScopedResource()
        }
      }

      let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if values.isRegularFile == false {
        throw BackupTransferViewError.fileIsNotRegular
      }
      if let fileSize = values.fileSize, fileSize > maximumByteCount {
        throw BackupTransferViewError.fileTooLarge(
          actual: fileSize,
          maximum: maximumByteCount
        )
      }

      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }

      var data = Data()
      if let fileSize = values.fileSize, fileSize > 0 {
        data.reserveCapacity(min(fileSize, maximumByteCount))
      }

      while true {
        try Task.checkCancellation()
        let remainingByteCount = maximumByteCount - data.count
        let requestedByteCount = min(chunkByteCount, remainingByteCount + 1)
        let chunk = try handle.read(upToCount: requestedByteCount) ?? Data()
        guard !chunk.isEmpty else { break }

        let (nextByteCount, overflow) = data.count.addingReportingOverflow(chunk.count)
        guard !overflow, nextByteCount <= maximumByteCount else {
          throw BackupTransferViewError.fileTooLarge(
            actual: overflow ? Int.max : nextByteCount,
            maximum: maximumByteCount
          )
        }
        data.append(chunk)
      }
      return data
    }.value
  }
}

struct BackupTransferView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: LibraryStore

  @State private var preparedBackup: PreparedBackup?
  @State private var pendingImport: PendingBackupImport?
  @State private var operationMessage: String?
  @State private var notice: BackupTransferNotice?
  @State private var isExporterPresented = false
  @State private var isImporterPresented = false

  var body: some View {
    NavigationStack {
      Form {
        if let operationMessage {
          Section {
            HStack(spacing: 12) {
              ProgressView()
              Text(operationMessage)
                .foregroundStyle(.secondary)
            }
          }
        }

        exportSection
        importSection
        privacySection
      }
      .navigationTitle("备份与恢复")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("完成") {
            dismiss()
          }
          .disabled(isBusy)
        }
      }
    }
    .fileExporter(
      isPresented: $isExporterPresented,
      item: preparedBackup?.item,
      contentTypes: [.notesBackup],
      defaultFilename: preparedBackup?.item.filename
    ) { result in
      handleExportResult(result)
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [.notesBackup]
    ) { result in
      handleImportSelection(result)
    }
    .confirmationDialog(
      "导入这份备份？",
      isPresented: importConfirmationIsPresented,
      titleVisibility: .visible
    ) {
      Button("作为副本导入") {
        guard let pendingImport else { return }
        self.pendingImport = nil
        Task {
          await restoreBackup(pendingImport)
        }
      }
      Button("取消", role: .cancel) {
        pendingImport = nil
      }
    } message: {
      if let pendingImport {
        Text(importConfirmationMessage(pendingImport))
      }
    }
    .alert(item: $notice) { notice in
      Alert(
        title: Text(notice.title),
        message: Text(notice.message),
        dismissButton: .default(Text("知道了"))
      )
    }
  }

  private var exportSection: some View {
    Section("导出备份") {
      Button {
        Task {
          await prepareLatestBackup()
        }
      } label: {
        Label("生成最新备份", systemImage: "arrow.clockwise.icloud")
      }
      .disabled(!canStartOperation)

      if let preparedBackup {
        LabeledContent("生成时间") {
          Text(preparedBackup.createdAt, format: .dateTime.year().month().day().hour().minute())
        }
        LabeledContent("内容") {
          Text("\(preparedBackup.notebookCount) 个笔记本，\(preparedBackup.pageCount) 页")
        }
        LabeledContent("文件大小") {
          Text(formatBackupByteCount(preparedBackup.item.data.count))
        }

        Label(
          "此备份未加密，包含笔记名称和原始笔迹；只存到你信任的位置或应用。",
          systemImage: "lock.open.trianglebadge.exclamationmark"
        )
        .font(.footnote)
        .foregroundStyle(.orange)

        Button {
          isExporterPresented = true
        } label: {
          Label("存储到文件", systemImage: "folder.badge.plus")
        }
        .disabled(isBusy)

        ShareLink(
          item: preparedBackup.item,
          subject: Text("未加密的笔记备份"),
          message: Text("此文件未加密，包含笔记名称和原始笔迹，请仅保存到信任的位置。"),
          preview: SharePreview(
            "笔记备份",
            image: Image(systemName: "doc.badge.arrow.up")
          )
        ) {
          Label("分享到其他应用", systemImage: "square.and.arrow.up")
        }
        .disabled(isBusy)
      } else {
        Text("先生成一次最新备份，再选择保存位置或通过其他应用分享。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var importSection: some View {
    Section("导入备份") {
      Button {
        isImporterPresented = true
      } label: {
        Label("选择备份文件", systemImage: "square.and.arrow.down")
      }
      .disabled(!canStartOperation)

      Text("文件会先经过格式、大小、完整性和笔迹校验；确认后以副本导入，不覆盖现有笔记。")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private var privacySection: some View {
    Section("隐私提示") {
      Label(
        "备份文件包含原始笔迹和笔记名称，当前未加密。",
        systemImage: "lock.open.trianglebadge.exclamationmark"
      )
      .foregroundStyle(.orange)

      Text("只有在你主动选择网盘或其他应用后，备份才会离开本机，并由相应第三方服务负责存储与保护。")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private var isBusy: Bool {
    operationMessage != nil || store.isBackupTransferInProgress
  }

  private var canStartOperation: Bool {
    operationMessage == nil && store.canManageBackups
  }

  private var importConfirmationIsPresented: Binding<Bool> {
    Binding(
      get: { pendingImport != nil },
      set: { if !$0 { pendingImport = nil } }
    )
  }

  @MainActor
  private func prepareLatestBackup() async {
    guard canStartOperation else { return }
    operationMessage = "正在生成最新备份…"
    defer { operationMessage = nil }

    do {
      let result = try await store.makeBackup()
      preparedBackup = PreparedBackup(
        item: BackupTransferItem(
          data: result.data,
          filename: backupFilename(createdAt: result.createdAt)
        ),
        createdAt: result.createdAt,
        notebookCount: result.notebookCount,
        pageCount: result.pageCount
      )
      notice = BackupTransferNotice(
        title: "未加密备份已生成",
        message: "此文件包含笔记名称和原始笔迹。请只存储到你信任的“文件”位置或应用。"
      )
    } catch {
      presentError(error, action: "生成备份失败")
    }
  }

  private func handleExportResult(_ result: Result<URL, Error>) {
    switch result {
    case .success:
      notice = BackupTransferNotice(
        title: "备份已导出",
        message: "未加密备份已保存到你选择的位置；该位置或第三方服务现在可以访问文件内容。"
      )
    case .failure(let error):
      presentError(error, action: "导出备份失败")
    }
  }

  private func handleImportSelection(_ result: Result<URL, Error>) {
    switch result {
    case .success(let url):
      Task {
        await inspectSelectedBackup(at: url)
      }
    case .failure(let error):
      presentError(error, action: "读取备份失败")
    }
  }

  @MainActor
  private func inspectSelectedBackup(at url: URL) async {
    guard canStartOperation else { return }
    operationMessage = "正在读取并校验备份…"
    defer { operationMessage = nil }

    do {
      let data = try await BackupFileReader.read(from: url)
      let preview = try await store.inspectBackup(data)
      pendingImport = PendingBackupImport(
        data: data,
        filename: url.lastPathComponent,
        preview: preview
      )
    } catch {
      presentError(error, action: "备份校验失败")
    }
  }

  @MainActor
  private func restoreBackup(_ pendingImport: PendingBackupImport) async {
    guard canStartOperation else { return }
    operationMessage = "正在作为副本导入…"
    defer { operationMessage = nil }

    do {
      let result = try await store.importBackupAsCopy(pendingImport.data)
      preparedBackup = nil
      switch result.disposition {
      case .imported:
        let message =
          "已新增 \(result.importedNotebookCount) 个笔记本、"
          + "\(result.importedPageCount) 页；原有笔记未被覆盖。"
        notice = BackupTransferNotice(
          title: "导入完成",
          message: message
        )
      case .alreadyImported:
        if result.repairedDrawingCount > 0 {
          notice = BackupTransferNotice(
            title: "恢复完成",
            message:
              "这份备份此前已导入；本次补回 \(result.repairedDrawingCount) 页缺失笔迹，"
              + "未新增笔记本或页面，也未覆盖已有笔迹。"
          )
        } else {
          notice = BackupTransferNotice(
            title: "无需重复导入",
            message: "这份备份此前已导入，本次未新增笔记本或页面，也未覆盖已有笔迹。"
          )
        }
      }
    } catch {
      presentError(error, action: "导入备份失败")
    }
  }

  private func importConfirmationMessage(_ pendingImport: PendingBackupImport) -> String {
    let preview = pendingImport.preview
    let createdAt = preview.createdAt.formatted(date: .abbreviated, time: .shortened)
    let source: String
    if preview.sourceAppVersion.isEmpty {
      source = "来源版本未知"
    } else if preview.sourceBuild.isEmpty {
      source = "版本 \(preview.sourceAppVersion)"
    } else {
      source = "版本 \(preview.sourceAppVersion)（\(preview.sourceBuild)）"
    }
    let contents =
      "\(preview.notebookCount) 个笔记本、\(preview.pageCount) 页"
    return
      "“\(pendingImport.filename)”创建于 \(createdAt)，包含 \(contents)，\(source)。"
      + "导入会创建副本，不覆盖现有笔记。"
  }

  private func backupFilename(createdAt: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return "笔记备份-\(formatter.string(from: createdAt)).\(BackupArchiveCodec.fileExtension)"
  }

  private func presentError(_ error: Error, action: String) {
    notice = BackupTransferNotice(
      title: action,
      message: error.localizedDescription
    )
  }
}
