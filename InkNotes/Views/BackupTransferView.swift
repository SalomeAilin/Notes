import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let notesBackup = UTType(
    exportedAs: BackupExportArtifact.uniformTypeIdentifier,
    conformingTo: .data
  )
}

private struct BackupTransferItem: Transferable, Sendable {
  let artifact: BackupExportArtifact

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .notesBackup) { item in
      item.artifact.data
    }
    .suggestedFileName { item in
      item.artifact.filename
    }
  }
}

private struct PreparedBackup: Sendable {
  let artifact: BackupExportArtifact
  let createdAt: Date
  let notebookCount: Int
  let pageCount: Int

  var transferItem: BackupTransferItem {
    BackupTransferItem(artifact: artifact)
  }
}

private struct PendingBackupImport: Sendable {
  let data: Data
  let filename: String
  let preview: BackupArchivePreview
  let inboxCleanupWarning: String?
}

private struct BackupImportConfirmationView: View {
  let pendingImport: PendingBackupImport
  let canImport: Bool
  let onCancel: () -> Void
  let onImport: () -> Void

  var body: some View {
    NavigationStack {
      List {
        Section("这份备份") {
          LabeledContent("文件") {
            Text(pendingImport.filename)
              .multilineTextAlignment(.trailing)
              .lineLimit(2)
          }
          LabeledContent("创建时间") {
            Text(
              pendingImport.preview.createdAt,
              format: .dateTime.year().month().day().hour().minute()
            )
          }
          LabeledContent("笔记内容") {
            Text(
              "\(pendingImport.preview.notebookCount) 个笔记本，"
                + "\(pendingImport.preview.pageCount) 页"
            )
          }
          LabeledContent("网页来源") {
            Text(sourceDescription)
          }
        }

        Section("导入后") {
          Label("会新增一份副本，原备份文件保持不变。", systemImage: "plus.square.on.square")
          Label("现有笔记、手写内容和网页来源不会被覆盖。", systemImage: "checkmark.shield")
        }

        if let warning = pendingImport.inboxCleanupWarning {
          Section("需要注意") {
            Label(warning, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
        }
      }
      .navigationTitle("确认导入")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消", action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("作为副本导入", action: onImport)
            .disabled(!canImport)
        }
      }
    }
  }

  private var sourceDescription: String {
    if pendingImport.preview.sourceCount == 0 {
      "无"
    } else {
      "\(pendingImport.preview.sourceCount) 条"
    }
  }
}

private enum BackupInspectionOutcome: Equatable {
  case consumed
  case notStarted
}

private struct BackupTransferNotice: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

private func formatBackupByteCount(_ count: Int) -> String {
  ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}

struct BackupTransferView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: LibraryStore
  @Binding var importQueue: BackupImportQueue

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
        appInformationSection
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
      item: preparedBackup?.transferItem,
      contentTypes: [.notesBackup],
      defaultFilename: preparedBackup?.artifact.filename
    ) { result in
      handleExportResult(result)
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [.notesBackup]
    ) { result in
      handleImportSelection(result)
    }
    .sheet(isPresented: importConfirmationIsPresented) {
      if let pendingImport {
        BackupImportConfirmationView(
          pendingImport: pendingImport,
          canImport: canStartOperation,
          onCancel: {
            self.pendingImport = nil
          },
          onImport: {
            guard canStartOperation else { return }
            operationMessage = "正在作为副本导入…"
            self.pendingImport = nil
            Task {
              await restoreBackup(pendingImport)
            }
          }
        )
        .presentationDetents([.medium, .large])
      }
    }
    .alert(item: $notice) { notice in
      Alert(
        title: Text(notice.title),
        message: Text(notice.message),
        dismissButton: .default(Text("知道了"))
      )
    }
    .task(id: importQueue.current?.id) {
      guard let request = importQueue.current else { return }
      await handleQueuedImportRequest(request)
    }
    .interactiveDismissDisabled(isBusy)
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
        LabeledContent("备份范围") {
          Text("全部手写内容和已保存的网页来源")
            .multilineTextAlignment(.trailing)
        }
        LabeledContent("文件大小") {
          Text(formatBackupByteCount(preparedBackup.artifact.data.count))
        }

        Label(
          "此备份未加密，包含笔记名称、原始笔迹和已保存的网页来源；只存到你信任的位置或应用。",
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
          item: preparedBackup.transferItem,
          subject: Text("未加密的笔记备份"),
          message: Text(
            "此文件未加密，包含笔记名称、原始笔迹和已保存的网页来源，请仅保存到信任的位置。"
          ),
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
        "备份文件包含笔记名称、原始笔迹和已保存的网页来源，当前未加密。",
        systemImage: "lock.open.trianglebadge.exclamationmark"
      )
      .foregroundStyle(.orange)

      Text(
        "应用不会主动上传笔记。导出或分享由你发起；系统设备备份（包括 iCloud 备份）是否包含应用数据，取决于你的设备设置。"
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
  }

  private var appInformationSection: some View {
    Section("应用信息") {
      LabeledContent("当前应用") {
        Text(AppBuildIdentity.current().displayText)
      }
    }
  }

  private var isBusy: Bool {
    operationMessage != nil || store.isBackupTransferInProgress || pendingImport != nil
      || isImporterPresented || isExporterPresented || !importQueue.isEmpty
  }

  private var canStartOperation: Bool {
    operationMessage == nil && !isImporterPresented && !isExporterPresented
      && store.canManageBackups
  }

  private var canInspectNewBackup: Bool {
    canStartOperation && pendingImport == nil && notice == nil
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
        artifact: BackupExportArtifact(
          data: result.data,
          createdAt: result.createdAt
        ),
        createdAt: result.createdAt,
        notebookCount: result.notebookCount,
        pageCount: result.pageCount
      )
      notice = BackupTransferNotice(
        title: "未加密备份已生成",
        message:
          "此文件包含笔记名称、原始笔迹和已保存的网页来源。"
          + "请只存储到你信任的“文件”位置或应用。"
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
      presentFilePickerFailure(error, action: "导出备份失败")
    }
  }

  private func handleImportSelection(_ result: Result<URL, Error>) {
    switch result {
    case .success(let url):
      guard let request = BackupImportRequest(url: url, source: .fileImporter) else {
        presentError(BackupFileReaderError.unsupportedURL, action: "读取备份失败")
        return
      }
      importQueue.enqueue(request)
    case .failure(let error):
      presentFilePickerFailure(error, action: "读取备份失败")
    }
  }

  @MainActor
  private func handleQueuedImportRequest(_ request: BackupImportRequest) async {
    do {
      while true {
        while !canInspectNewBackup {
          try Task.checkCancellation()
          if canReportReadOnlyImportFailure {
            let cleanupWarning = cleanupWarning(for: request.url, source: request.source)
            let message = [
              "应用处于只读保护状态，未读取或导入这份备份。",
              cleanupWarning,
            ]
            .compactMap { $0 }
            .joined(separator: "\n\n")
            notice = BackupTransferNotice(
              title: "无法校验备份",
              message: message
            )
            clearQueuedImportRequest(ifMatching: request.id)
            return
          }
          try await Task.sleep(for: .milliseconds(100))
        }

        try Task.checkCancellation()
        let outcome = try await inspectSelectedBackup(at: request.url, source: request.source)
        guard outcome == .consumed else { continue }
        clearQueuedImportRequest(ifMatching: request.id)
        return
      }
    } catch is CancellationError {
      return
    } catch {
      presentError(error, action: "读取备份失败")
      clearQueuedImportRequest(ifMatching: request.id)
    }
  }

  private func clearQueuedImportRequest(ifMatching requestID: UUID) {
    importQueue.removeCurrent(ifMatching: requestID)
  }

  private var canReportReadOnlyImportFailure: Bool {
    store.isReadOnly && pendingImport == nil && operationMessage == nil && notice == nil
      && !isImporterPresented && !isExporterPresented
  }

  @MainActor
  private func inspectSelectedBackup(
    at url: URL,
    source: BackupImportSource
  ) async throws -> BackupInspectionOutcome {
    guard canInspectNewBackup else { return .notStarted }
    operationMessage = "正在读取并校验备份…"
    defer { operationMessage = nil }

    do {
      let data = try await BackupFileReader().read(from: url)
      let preview = try await store.inspectBackup(data)
      let inboxCleanupWarning = cleanupWarning(for: url, source: source)
      pendingImport = PendingBackupImport(
        data: data,
        filename: url.lastPathComponent,
        preview: preview,
        inboxCleanupWarning: inboxCleanupWarning
      )
      return .consumed
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      presentError(
        error,
        action: "备份校验失败",
        additionalMessage: cleanupWarning(for: url, source: source)
      )
      return .consumed
    }
  }

  @MainActor
  private func restoreBackup(_ pendingImport: PendingBackupImport) async {
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
          message: appendingInboxCleanupWarning(to: message, pendingImport: pendingImport)
        )
      case .alreadyImported:
        if result.repairedDrawingCount > 0 || result.repairedSourceCount > 0 {
          let repairedDescription: String
          if result.repairedDrawingCount > 0, result.repairedSourceCount > 0 {
            repairedDescription =
              "\(result.repairedDrawingCount) 页缺失笔迹和 "
              + "\(result.repairedSourceCount) 页缺失来源"
          } else if result.repairedDrawingCount > 0 {
            repairedDescription = "\(result.repairedDrawingCount) 页缺失笔迹"
          } else {
            repairedDescription = "\(result.repairedSourceCount) 页缺失来源"
          }
          notice = BackupTransferNotice(
            title: "恢复完成",
            message:
              appendingInboxCleanupWarning(
                to:
                  "这份备份此前已导入；本次补回 \(repairedDescription)，"
                  + "未新增笔记本或页面，也未覆盖已有内容。",
                pendingImport: pendingImport
              )
          )
        } else {
          notice = BackupTransferNotice(
            title: "无需重复导入",
            message: appendingInboxCleanupWarning(
              to: "这份备份此前已导入，本次未新增笔记本或页面，也未覆盖已有内容。",
              pendingImport: pendingImport
            )
          )
        }
      }
    } catch {
      presentError(
        error,
        action: "导入备份失败",
        additionalMessage: pendingImport.inboxCleanupWarning
      )
    }
  }

  private func cleanupWarning(for url: URL, source: BackupImportSource) -> String? {
    guard source == .externalOpen else { return nil }
    do {
      _ = try BackupInboxCopyCleaner().removeIfInboxCopy(at: url)
      return nil
    } catch {
      return "系统交付的临时备份副本未能自动清理：\(error.localizedDescription)"
    }
  }

  private func appendingInboxCleanupWarning(
    to message: String,
    pendingImport: PendingBackupImport
  ) -> String {
    guard let warning = pendingImport.inboxCleanupWarning else { return message }
    return "\(message)\n\n\(warning)"
  }

  private func presentFilePickerFailure(_ error: Error, action: String) {
    guard BackupFilePickerFailurePolicy.disposition(for: error) == .report else { return }
    presentError(error, action: action)
  }

  private func presentError(
    _ error: Error,
    action: String,
    additionalMessage: String? = nil
  ) {
    let message = [error.localizedDescription, additionalMessage]
      .compactMap { $0 }
      .joined(separator: "\n\n")
    notice = BackupTransferNotice(
      title: action,
      message: message
    )
  }
}
