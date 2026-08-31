// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "InkNotesCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "InkNotesCore", targets: ["InkNotesCore"])
  ],
  targets: [
    .target(
      name: "InkNotesCore",
      path: "InkNotes",
      exclude: ["App", "Assets.xcassets", "Info.plist", "PrivacyInfo.xcprivacy", "Views"],
      sources: [
        "Models/AppBuildIdentity.swift",
        "Models/BackupArchive.swift",
        "Models/BackupExportArtifact.swift",
        "Models/BackupImportPresentationState.swift",
        "Models/BackupImportRequest.swift",
        "Models/BaiduAccountCredential.swift",
        "Models/BaiduBrokerProtocolV1.swift",
        "Models/BaiduNetdiskAccount.swift",
        "Models/BaiduNetdiskBackup.swift",
        "Models/LibraryDocument.swift",
        "Networking/BaiduBackupUploadCoordinator.swift",
        "Networking/BaiduHTTPTransport.swift",
        "Networking/BaiduNetdiskAccountResolver.swift",
        "Networking/BaiduNetdiskBackupUploader.swift",
        "Networking/BaiduRemoteBackupContentVerifier.swift",
        "Networking/BaiduRemoteBackupReconciliationAuthority.swift",
        "Networking/BaiduRemoteBackupMetadataObserver.swift",
        "Persistence/BackupArchiveCodec.swift",
        "Persistence/BackupFileReader.swift",
        "Persistence/BackupSnapshotRepository.swift",
        "Persistence/BaiduUploadReconciliationRepository.swift",
        "Persistence/DrawingRepository.swift",
        "Persistence/DurableFileWriter.swift",
        "Stores/LibraryStore.swift",
      ]
    ),
    .testTarget(
      name: "InkNotesCoreTests",
      dependencies: ["InkNotesCore"],
      path: "InkNotesCoreTests",
      resources: [.copy("Fixtures")]
    ),
  ]
)
