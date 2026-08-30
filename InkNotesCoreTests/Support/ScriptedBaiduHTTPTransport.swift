import Foundation

@testable import InkNotesCore

enum ScriptedBaiduHTTPTransportError: Error, Sendable {
  case unexpectedRequest
}

actor ScriptedBaiduHTTPTransport: BaiduHTTPTransport {
  typealias Handler = @Sendable (URLRequest) async throws -> BaiduHTTPResponse

  private var handlers: [Handler]
  private var capturedRequests: [URLRequest] = []

  init(handlers: [Handler]) {
    self.handlers = handlers
  }

  func send(_ request: URLRequest) async throws -> BaiduHTTPResponse {
    capturedRequests.append(request)
    guard !handlers.isEmpty else {
      throw ScriptedBaiduHTTPTransportError.unexpectedRequest
    }
    let handler = handlers.removeFirst()
    return try await handler(request)
  }

  func requests() -> [URLRequest] {
    capturedRequests
  }

  func requestCount() -> Int {
    capturedRequests.count
  }
}

final class ControlledBaiduURLProtocol: URLProtocol, @unchecked Sendable {
  enum Scenario: Sendable {
    case response(statusCode: Int, headers: [String: String], chunks: [Data])
    case hanging(statusCode: Int)
  }

  private final class Store: @unchecked Sendable {
    private let lock = NSLock()
    private var scenarios: [String: Scenario] = [:]
    private var requestCounts: [String: Int] = [:]
    private var stopCounts: [String: Int] = [:]

    func register(_ scenario: Scenario, path: String) {
      lock.lock()
      scenarios[path] = scenario
      requestCounts[path] = 0
      stopCounts[path] = 0
      lock.unlock()
    }

    func begin(path: String) -> Scenario? {
      lock.lock()
      requestCounts[path, default: 0] += 1
      let scenario = scenarios[path]
      lock.unlock()
      return scenario
    }

    func recordStop(path: String) {
      lock.lock()
      stopCounts[path, default: 0] += 1
      lock.unlock()
    }

    func requestCount(path: String) -> Int {
      lock.lock()
      let count = requestCounts[path, default: 0]
      lock.unlock()
      return count
    }

    func stopCount(path: String) -> Int {
      lock.lock()
      let count = stopCounts[path, default: 0]
      lock.unlock()
      return count
    }
  }

  private static let store = Store()
  private let stateLock = NSLock()
  private var stopped = false

  static func register(_ scenario: Scenario, path: String) {
    store.register(scenario, path: path)
  }

  static func requestCount(path: String) -> Int {
    store.requestCount(path: path)
  }

  static func stopCount(path: String) -> Int {
    store.stopCount(path: path)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    guard let host = request.url?.host else { return false }
    return host == "baidu-transport.test" || host == "d.pcs.baidu.com"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let path = request.url?.path ?? "/"
    guard let scenario = Self.store.begin(path: path), let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }

    switch scenario {
    case .response(let statusCode, let headers, let chunks):
      guard
        let response = HTTPURLResponse(
          url: url,
          statusCode: statusCode,
          httpVersion: "HTTP/1.1",
          headerFields: headers
        )
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      for chunk in chunks where !isStopped {
        client?.urlProtocol(self, didLoad: chunk)
      }
      if !isStopped {
        client?.urlProtocolDidFinishLoading(self)
      }

    case .hanging(let statusCode):
      guard
        let response = HTTPURLResponse(
          url: url,
          statusCode: statusCode,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
  }

  override func stopLoading() {
    stateLock.lock()
    stopped = true
    stateLock.unlock()
    Self.store.recordStop(path: request.url?.path ?? "/")
  }

  private var isStopped: Bool {
    stateLock.lock()
    let value = stopped
    stateLock.unlock()
    return value
  }
}
