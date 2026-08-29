import SwiftUI
import UIKit

@main
@MainActor
struct InkNotesApp: App {
  @StateObject private var store = LibraryStore()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      LibrarySplitView()
        .environmentObject(store)
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase != .active else { return }
      flushWithBackgroundTime()
    }
  }

  private func flushWithBackgroundTime() {
    let application = UIApplication.shared
    var taskIdentifier = UIBackgroundTaskIdentifier.invalid
    taskIdentifier = application.beginBackgroundTask(withName: "保存本地笔记") {
      if taskIdentifier != .invalid {
        application.endBackgroundTask(taskIdentifier)
        taskIdentifier = .invalid
      }
    }

    Task {
      await store.flush()
      if taskIdentifier != .invalid {
        application.endBackgroundTask(taskIdentifier)
        taskIdentifier = .invalid
      }
    }
  }
}
