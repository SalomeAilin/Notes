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
  let libraryRevisionSHA256: String

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
        Section("检查结果") {
          Label("文件检查完成，可以选择是否恢复。", systemImage: "checkmark.shield")
            .foregroundStyle(.green)
        }

        Section("备份内容") {
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

        Section("恢复方式") {
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
      .navigationTitle("备份检查完成")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("暂不恢复", action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("作为副本恢复", action: onImport)
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
  @AppStorage(BackupSaveStatus.storageKey) private var lastSuccessfulBackupSaveTimestamp = 0.0
  @AppStorage(BackupSaveStatus.legacyRecordStorageKey) private var legacyBackupSaveRecord = Data()
  @AppStorage(BackupSaveStatus.previousVerifiedRecordStorageKey) private
    var previousVerifiedBackupSaveRecord = Data()
  @AppStorage(BackupSaveStatus.recordStorageKey) private var lastSuccessfulBackupSaveRecord =
    Data()

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
            operationMessage = "正在作为副本恢复…"
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
    Section("保存备份") {
      Button {
        Task {
          await saveLatestBackup()
        }
      } label: {
        Label("保存最新备份", systemImage: "folder.badge.plus")
      }
      .disabled(!canStartOperation)

      backupSaveStatusContent

      Text(
        "状态只在刚保存的文件能够完整读回且内容一致时更新；只记录保存时间、当时的笔记本和页数，以及不含内容的修订标记，不记录内容、名称或位置。如果选择网盘，长期同步情况请以网盘中的文件为准。"
      )
      .font(.footnote)
      .foregroundStyle(.secondary)

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
        Text("点击后会先整理当前全部内容，再由你选择“文件”或已出现在“文件”中的网盘位置。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var importSection: some View {
    Section("检查或恢复备份") {
      Button {
        isImporterPresented = true
      } label: {
        Label("选择并检查备份", systemImage: "square.and.arrow.down")
      }
      .disabled(!canStartOperation)

      Text("选择后只会检查文件，不会立即修改笔记。检查通过后，再由你决定是否作为副本恢复。")
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
        "应用不会主动上传笔记。保存位置和分享对象都由你选择；系统设备备份（包括 iCloud 备份）是否包含应用数据，取决于你的设备设置。"
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

  private var backupSaveFreshness: BackupSaveFreshness {
    BackupSaveStatus.freshness(
      recordData: lastSuccessfulBackupSaveRecord,
      previousVerifiedRecordData: previousVerifiedBackupSaveRecord,
      legacyRecordData: legacyBackupSaveRecord,
      legacyTimestamp: lastSuccessfulBackupSaveTimestamp,
      library: store.library
    )
  }

  @ViewBuilder
  private var backupSaveStatusContent: some View {
    switch backupSaveFreshness {
    case .noRecord:
      Label("这里还没有保存记录", systemImage: "clock")
        .foregroundStyle(.secondary)
    case .unchangedSinceSave(let savedAt):
      Label("保存后没有新的修改", systemImage: "checkmark.circle")
        .foregroundStyle(.green)
      backupSaveDateRow(savedAt)
    case .changedSinceSave(let savedAt):
      Label("保存后有新的修改，建议再次保存", systemImage: "exclamationmark.circle")
        .foregroundStyle(.orange)
      backupSaveDateRow(savedAt)
    case .unknown(let savedAt):
      Label("建议重新保存一次，以确认当前内容", systemImage: "arrow.clockwise.circle")
        .foregroundStyle(.orange)
      backupSaveDateRow(savedAt)
    }
  }

  private func backupSaveDateRow(_ date: Date) -> some View {
    LabeledContent("上次保存") {
      Text(date, format: .dateTime.year().month().day().hour().minute())
    }
  }

  private var importConfirmationIsPresented: Binding<Bool> {
    Binding(
      get: { pendingImport != nil },
      set: { if !$0 { pendingImport = nil } }
    )
  }

  @MainActor
  private func saveLatestBackup() async {
    guard canStartOperation else { return }
    operationMessage = "正在整理最新备份…"

    do {
      let result = try await store.makeBackup()
      preparedBackup = PreparedBackup(
        artifact: BackupExportArtifact(
          data: result.data,
          createdAt: result.createdAt
        ),
        createdAt: result.createdAt,
        notebookCount: result.notebookCount,
        pageCount: result.pageCount,
        libraryRevisionSHA256: result.libraryRevisionSHA256
      )
      operationMessage = nil
      isExporterPresented = true
    } catch {
      operationMessage = nil
      presentError(error, action: "保存备份失败")
    }
  }

  private func handleExportResult(_ result: Result<URL, Error>) {
    switch result {
    case .success(let url):
      Task {
        await verifySavedBackup(at: url)
      }
    case .failure(let error):
      presentFilePickerFailure(error, action: "保存备份失败")
    }
  }

  @MainActor
  private func verifySavedBackup(at url: URL) async {
    guard let preparedBackup else {
      notice = BackupTransferNotice(
        title: "备份可能已保存",
        message: "系统已完成保存，但应用没有找到本次备份用于核对；保存状态未更新。请在所选位置检查文件，必要时重新保存。"
      )
      return
    }

    operationMessage = "正在确认刚保存的备份…"
    defer { operationMessage = nil }

    do {
      let verification = try await BackupSavedFileVerifier().verify(
        fileURL: url,
        expectedData: preparedBackup.artifact.data
      )
      switch verification {
      case .verified:
        if let record = BackupSaveStatus.recordData(
          savedAt: Date(),
          notebookCount: preparedBackup.notebookCount,
          pageCount: preparedBackup.pageCount,
          libraryRevisionSHA256: preparedBackup.libraryRevisionSHA256
        ) {
          lastSuccessfulBackupSaveRecord = record
        }
        notice = BackupTransferNotice(
          title: "备份已保存并确认",
          message: "已确认刚保存的文件与本次备份一致。若选择了网盘，长期同步情况仍以网盘中的实际文件为准。"
        )
      case .contentMismatch:
        notice = BackupTransferNotice(
          title: "保存结果需要检查",
          message: "重新读取的文件与刚生成的备份不一致，保存状态未更新。请换一个位置重新保存。"
        )
      }
    } catch is CancellationError {
      notice = BackupTransferNotice(
        title: "未完成保存确认",
        message: "没有完成刚保存文件的读取核对，保存状态未更新。请在所选位置检查文件，必要时重新保存。"
      )
    } catch {
      notice = BackupTransferNotice(
        title: "备份可能已保存",
        message: "系统已完成保存，但应用暂时无法重新读取确认，保存状态未更新。请在所选位置检查文件，必要时重新保存。"
      )
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
      presentFilePickerFailure(error, action: "检查备份失败")
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
              "应用处于只读保护状态，未检查或恢复这份备份。",
              cleanupWarning,
            ]
            .compactMap { $0 }
            .joined(separator: "\n\n")
            notice = BackupTransferNotice(
              title: "无法检查备份",
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
      presentError(error, action: "检查备份失败")
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
    operationMessage = "正在读取并检查备份…"
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
        action: "备份检查失败",
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
          title: "恢复完成",
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
                  "这份备份此前已恢复；本次补回 \(repairedDescription)，"
                  + "未新增笔记本或页面，也未覆盖已有内容。",
                pendingImport: pendingImport
              )
          )
        } else {
          notice = BackupTransferNotice(
            title: "无需重复恢复",
            message: appendingInboxCleanupWarning(
              to: "这份备份此前已恢复，本次未新增笔记本或页面，也未覆盖已有内容。",
              pendingImport: pendingImport
            )
          )
        }
      }
    } catch {
      presentError(
        error,
        action: "恢复备份失败",
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
