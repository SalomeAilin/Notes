import SwiftUI
import WebKit

struct PageSourceBrowserView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: LibraryStore
  @StateObject private var browser = PageSourceBrowserController()
  @State private var address = ""
  @State private var pendingSource: PageSourceExcerpt?
  @State private var alert: PageSourceBrowserAlert?
  @State private var showingSavedSources = false
  @State private var isReadingSelection = false
  @State private var isSaving = false

  let pageID: UUID

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        addressBar
        Divider()

        if browser.hasOpenedPage {
          PageSourceWebView(controller: browser)
        } else {
          ContentUnavailableView(
            "打开网页资料",
            systemImage: "safari",
            description: Text("输入网址并点“打开”。应用不会自动访问网页。")
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .navigationTitle("网页资料")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        saveSelectionBar
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") {
            dismiss()
          }
        }
        ToolbarItem(placement: .secondaryAction) {
          savedSourcesMenu
        }
      }
      .sheet(item: $pendingSource) { source in
        PageSourceConfirmationView(
          source: source,
          isSaving: isSaving,
          onCancel: {
            pendingSource = nil
          },
          onSave: {
            save(source)
          }
        )
        .presentationDetents([.medium, .large])
      }
      .sheet(isPresented: $showingSavedSources) {
        PageSourceListView(
          sources: store.currentPageSources,
          isSourceUpdateInProgress: store.isPageSourceSaveInProgress,
          onOpen: { source in
            showingSavedSources = false
            address = source.sourceURL.absoluteString
            browser.open(source.sourceURL)
          },
          onDelete: { source in
            try await store.deletePageSource(source.id, from: pageID)
          }
        )
        .presentationDetents([.medium, .large])
      }
      .alert(item: $alert) { alert in
        Alert(
          title: Text(alert.title),
          message: Text(alert.message),
          dismissButton: .default(Text("知道了"))
        )
      }
      .onChange(of: browser.message) {
        guard let message = browser.message else { return }
        alert = PageSourceBrowserAlert(title: "网页提示", message: message)
        browser.clearMessage()
      }
      .onChange(of: browser.currentURL) {
        if let currentURL = browser.currentURL {
          address = currentURL.absoluteString
        }
      }
    }
    .interactiveDismissDisabled(isSaving)
  }

  private var addressBar: some View {
    HStack(spacing: 10) {
      if browser.hasOpenedPage {
        Button {
          browser.goBack()
        } label: {
          Image(systemName: "chevron.backward")
        }
        .accessibilityLabel("后退")
        .disabled(!browser.canGoBack)

        Button {
          browser.goForward()
        } label: {
          Image(systemName: "chevron.forward")
        }
        .accessibilityLabel("前进")
        .disabled(!browser.canGoForward)
      }

      TextField("输入网址", text: $address)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
        .textContentType(.URL)
        .submitLabel(.go)
        .onSubmit(openAddress)

      Button("打开", action: openAddress)
        .buttonStyle(.borderedProminent)
        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

      if browser.isLoading {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private var saveSelectionBar: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("只保存你选中的文字")
          .font(.callout.weight(.semibold))
        Text("点击后会先预览，不会自动保存整页。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        readSelection()
      } label: {
        if isReadingSelection {
          ProgressView()
        } else {
          Label("保存选中文字", systemImage: "text.badge.plus")
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(
        !browser.hasOpenedPage || browser.isLoading || isReadingSelection || isSaving
          || store.isReadOnly || store.isBackupTransferInProgress
          || store.isPageSourceSaveInProgress
      )
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.bar)
  }

  @ViewBuilder
  private var savedSourcesMenu: some View {
    if store.currentPageSources.isEmpty {
      Label("本页暂无来源", systemImage: "bookmark")
        .foregroundStyle(.secondary)
    } else {
      Button {
        showingSavedSources = true
      } label: {
        Label(
          "本页来源 \(store.currentPageSources.count)",
          systemImage: "bookmark.fill"
        )
      }
    }
  }

  private func openAddress() {
    do {
      let url = try PageSourceBrowserAddress.makeURL(from: address)
      address = url.absoluteString
      browser.open(url)
    } catch {
      alert = PageSourceBrowserAlert(
        title: "无法打开网页",
        message: error.localizedDescription
      )
    }
  }

  private func readSelection() {
    isReadingSelection = true
    Task {
      defer { isReadingSelection = false }
      do {
        pendingSource = try await browser.selectedSource()
      } catch {
        alert = PageSourceBrowserAlert(
          title: "无法保存这段文字",
          message: error.localizedDescription
        )
      }
    }
  }

  private func save(_ source: PageSourceExcerpt) {
    isSaving = true
    Task {
      defer { isSaving = false }
      do {
        try await store.savePageSource(source, to: pageID)
        pendingSource = nil
        alert = PageSourceBrowserAlert(
          title: "已保存",
          message: "这段文字和网页链接已保存到当前页。"
        )
      } catch {
        alert = PageSourceBrowserAlert(
          title: "暂时无法保存",
          message: error.localizedDescription
        )
      }
    }
  }
}

private struct PageSourceListView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var alert: PageSourceListAlert?
  @State private var isDeleting = false

  let sources: [PageSourceExcerpt]
  let isSourceUpdateInProgress: Bool
  let onOpen: (PageSourceExcerpt) -> Void
  let onDelete: (PageSourceExcerpt) async throws -> Void

  var body: some View {
    NavigationStack {
      Group {
        if sources.isEmpty {
          ContentUnavailableView(
            "本页暂无来源",
            systemImage: "bookmark",
            description: Text("返回网页选中文字后，可以保存到当前页。")
          )
        } else {
          List(sources) { source in
            sourceRow(source)
          }
        }
      }
      .navigationTitle("本页来源")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") {
            dismiss()
          }
          .disabled(isDeleting)
        }
        if isDeleting || isSourceUpdateInProgress {
          ToolbarItem(placement: .confirmationAction) {
            ProgressView()
          }
        }
      }
      .alert(item: $alert) { alert in
        switch alert {
        case .confirmDeletion(let source):
          Alert(
            title: Text("删除这个来源？"),
            message: Text("只会删除当前页保存的这条文字和链接，不会影响网页或笔记内容。"),
            primaryButton: .destructive(Text("删除来源")) {
              delete(source)
            },
            secondaryButton: .cancel(Text("取消"))
          )
        case .error(_, let message):
          Alert(
            title: Text("暂时无法删除"),
            message: Text(message),
            dismissButton: .default(Text("知道了"))
          )
        }
      }
    }
    .interactiveDismissDisabled(isDeleting)
  }

  private func sourceRow(_ source: PageSourceExcerpt) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(source.title)
        .font(.headline)
      Text(source.excerpt)
        .font(.body)
        .lineLimit(3)
      Text(source.sourceURL.absoluteString)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      HStack {
        Button {
          onOpen(source)
        } label: {
          Label("打开网页", systemImage: "safari")
        }
        .buttonStyle(.bordered)

        Button(role: .destructive) {
          alert = .confirmDeletion(source)
        } label: {
          Label("删除来源", systemImage: "trash")
        }
        .buttonStyle(.bordered)
      }
      .disabled(isDeleting || isSourceUpdateInProgress)
    }
    .padding(.vertical, 4)
  }

  private func delete(_ source: PageSourceExcerpt) {
    isDeleting = true
    Task {
      defer { isDeleting = false }
      do {
        try await onDelete(source)
      } catch {
        alert = .error(UUID(), error.localizedDescription)
      }
    }
  }
}

private enum PageSourceListAlert: Identifiable {
  case confirmDeletion(PageSourceExcerpt)
  case error(UUID, String)

  var id: UUID {
    switch self {
    case .confirmDeletion(let source): source.id
    case .error(let id, _): id
    }
  }
}

private struct PageSourceConfirmationView: View {
  let source: PageSourceExcerpt
  let isSaving: Bool
  let onCancel: () -> Void
  let onSave: () -> Void

  var body: some View {
    NavigationStack {
      List {
        Section("将保存到当前页") {
          Text(source.excerpt)
            .textSelection(.enabled)
        }
        Section("网页来源") {
          Text(source.title)
          Text(source.sourceURL.absoluteString)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      .navigationTitle("确认保存")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消", action: onCancel)
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存到当前页", action: onSave)
            .disabled(isSaving)
        }
      }
    }
    .interactiveDismissDisabled(isSaving)
  }
}

private struct PageSourceBrowserAlert: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

enum PageSourceBrowserAddress {
  static func makeURL(from input: String) throws -> URL {
    let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else {
      throw PageSourceError.invalidURL
    }
    let candidate = cleaned.contains("://") ? cleaned : "https://\(cleaned)"
    guard let url = URL(string: candidate) else {
      throw PageSourceError.invalidURL
    }
    _ = try PageSourceExcerpt(
      title: "网页",
      excerpt: "网址检查",
      sourceURL: url,
      capturedAt: Date(timeIntervalSince1970: 0)
    ).validated()
    return url
  }
}

@MainActor
private final class PageSourceBrowserController: NSObject, ObservableObject {
  @Published private(set) var hasOpenedPage = false
  @Published private(set) var isLoading = false
  @Published private(set) var currentURL: URL?
  @Published private(set) var canGoBack = false
  @Published private(set) var canGoForward = false
  @Published private(set) var message: String?

  fileprivate weak var webView: WKWebView?
  private var pendingURL: URL?

  func attach(_ webView: WKWebView) {
    self.webView = webView
    if let pendingURL {
      self.pendingURL = nil
      load(pendingURL, in: webView)
    }
  }

  func open(_ url: URL) {
    guard isAllowed(url) else {
      message = PageSourceError.invalidURL.localizedDescription
      return
    }
    hasOpenedPage = true
    if let webView {
      load(url, in: webView)
    } else {
      pendingURL = url
    }
  }

  func selectedSource() async throws -> PageSourceExcerpt {
    guard let webView, let currentURL = webView.url, isAllowed(currentURL) else {
      throw PageSourceError.invalidURL
    }
    let script = """
      (() => {
        const selection = window.getSelection ? window.getSelection().toString() : "";
        const excerpt = Array.from(selection).slice(0, 16385).join("");
        const title = Array.from(document.title || location.hostname || "网页来源")
          .slice(0, 1025).join("");
        return { title, excerpt, url: location.href };
      })()
      """
    let value = try await webView.evaluateJavaScript(script)
    guard let result = value as? [String: Any],
      let title = result["title"] as? String,
      let excerpt = result["excerpt"] as? String,
      let urlString = result["url"] as? String,
      let sourceURL = URL(string: urlString),
      sourceURL == currentURL
    else {
      throw PageSourceError.invalidDocument
    }
    return try PageSourceExcerpt(
      title: title,
      excerpt: excerpt,
      sourceURL: sourceURL
    ).validated()
  }

  func clearMessage() {
    message = nil
  }

  func goBack() {
    guard webView?.canGoBack == true else { return }
    webView?.goBack()
  }

  func goForward() {
    guard webView?.canGoForward == true else { return }
    webView?.goForward()
  }

  fileprivate func setLoading(_ loading: Bool) {
    isLoading = loading
  }

  fileprivate func synchronizeNavigationState(from webView: WKWebView) {
    currentURL = webView.url
    canGoBack = webView.canGoBack
    canGoForward = webView.canGoForward
  }

  fileprivate func reject(_ message: String) {
    self.message = message
  }

  fileprivate func handleNavigationFailure(_ error: Error) {
    setLoading(false)
    let error = error as NSError
    guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else {
      return
    }
    reject("网页未能打开，请检查网络或网址后重试。")
  }

  fileprivate func isAllowed(_ url: URL) -> Bool {
    guard
      let components = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
      )
    else { return false }
    return components.scheme?.lowercased() == "https"
      && components.host?.isEmpty == false
      && components.user == nil
      && components.password == nil
      && url.absoluteString.utf8.count <= PageSourceLimits.maximumURLUTF8ByteCount
  }

  private func load(_ url: URL, in webView: WKWebView) {
    webView.load(
      URLRequest(
        url: url,
        cachePolicy: .reloadRevalidatingCacheData,
        timeoutInterval: 30
      )
    )
  }
}

private struct PageSourceWebView: UIViewRepresentable {
  @ObservedObject var controller: PageSourceBrowserController

  func makeCoordinator() -> Coordinator {
    Coordinator(controller: controller)
  }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.allowsBackForwardNavigationGestures = true
    controller.attach(webView)
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {
    controller.attach(webView)
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    private let controller: PageSourceBrowserController

    init(controller: PageSourceBrowserController) {
      self.controller = controller
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
      if navigationAction.targetFrame?.isMainFrame == false {
        return .allow
      }
      guard let url = navigationAction.request.url, controller.isAllowed(url) else {
        controller.reject("只能打开安全网页链接。")
        return .cancel
      }
      if navigationAction.targetFrame == nil {
        webView.load(navigationAction.request)
        return .cancel
      }
      return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      controller.setLoading(true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      controller.setLoading(false)
      controller.synchronizeNavigationState(from: webView)
    }

    func webView(
      _ webView: WKWebView,
      didFail navigation: WKNavigation!,
      withError error: Error
    ) {
      controller.handleNavigationFailure(error)
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      controller.handleNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      controller.setLoading(false)
      controller.reject("网页已停止运行，请重新打开。")
    }
  }
}
