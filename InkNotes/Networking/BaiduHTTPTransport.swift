import Foundation

struct BaiduHTTPResponse: Sendable {
  let statusCode: Int
  let headers: [String: String]
  let body: Data
}

protocol BaiduHTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> BaiduHTTPResponse
}

enum BaiduHTTPTransportError: Error, Equatable, Sendable {
  case invalidResponse
  case responseTooLarge(maximum: Int)
  case network(URLError.Code)
  case unavailable
}

struct URLSessionBaiduHTTPTransport: BaiduHTTPTransport {
  static let maximumResponseByteCount = 256 * 1024

  private let session: URLSession
  private let maximumResponseByteCount: Int

  init(
    session: URLSession = URLSession(configuration: .ephemeral),
    maximumResponseByteCount: Int = Self.maximumResponseByteCount
  ) {
    precondition(maximumResponseByteCount >= 0)
    self.session = session
    self.maximumResponseByteCount = maximumResponseByteCount
  }

  func send(_ request: URLRequest) async throws -> BaiduHTTPResponse {
    do {
      try Task.checkCancellation()
      let (bytes, response) = try await session.bytes(
        for: request,
        delegate: BaiduNoRedirectDelegate()
      )
      guard let response = response as? HTTPURLResponse else {
        bytes.task.cancel()
        throw BaiduHTTPTransportError.invalidResponse
      }

      var body = Data()
      body.reserveCapacity(min(maximumResponseByteCount, 16 * 1024))
      for try await byte in bytes {
        try Task.checkCancellation()
        guard body.count < maximumResponseByteCount else {
          bytes.task.cancel()
          throw BaiduHTTPTransportError.responseTooLarge(
            maximum: maximumResponseByteCount
          )
        }
        body.append(byte)
      }

      var headers: [String: String] = [:]
      for (name, value) in response.allHeaderFields {
        guard let name = name as? String else { continue }
        headers[name.lowercased()] = String(describing: value)
      }
      return BaiduHTTPResponse(
        statusCode: response.statusCode,
        headers: headers,
        body: body
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as URLError {
      throw BaiduHTTPTransportError.network(error.code)
    } catch let error as BaiduHTTPTransportError {
      throw error
    } catch {
      throw BaiduHTTPTransportError.unavailable
    }
  }
}

final class BaiduNoRedirectDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
