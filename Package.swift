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
      exclude: ["App", "Assets.xcassets", "Info.plist", "Views"],
      sources: [
        "Models/BackupArchive.swift",
        "Models/LibraryDocument.swift",
        "Persistence/BackupArchiveCodec.swift",
        "Persistence/BackupSnapshotRepository.swift",
        "Persistence/DrawingRepository.swift",
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
