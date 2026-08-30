import Foundation

protocol BaiduAccountResolving: Sendable {
  func resolveAccountIdentity(accessToken: BaiduAccessToken) async throws
    -> BaiduAccountIdentity
}

enum BaiduNetdiskAccountResolutionError: LocalizedError, Equatable, Sendable {
  case requestEncoding
  case transport
  case invalidHTTPResponse
  case httpStatus(Int)
  case responseTooLarge(maximum: Int)
  case malformedResponse
  case api(Int)
  case invalidAccountIdentity

  var errorDescription: String? {
    switch self {
    case .requestEncoding:
      "无法安全构造百度网盘账户验证请求。"
    case .transport:
      "连接百度网盘失败，请检查网络后重试。"
    case .invalidHTTPResponse:
      "百度网盘返回了无效的网络响应。"
    case .httpStatus(let statusCode):
      "百度网盘账户验证失败（HTTP \(statusCode)）。"
    case .responseTooLarge:
      "百度网盘账户响应超过安全上限。"
    case .malformedResponse:
      "百度网盘账户响应无法验证。"
    case .api(let code):
      "百度网盘拒绝了账户验证（错误码 \(code)）。"
    case .invalidAccountIdentity:
      "百度网盘没有返回有效的账户身份。"
    }
  }
}

struct BaiduNetdiskAccountResolver: BaiduAccountResolving, Sendable {
  static let maximumJSONResponseByteCount = 64 * 1024

  private static let endpoint = URL(
    string: "https://pan.baidu.com/rest/2.0/xpan/nas"
  )!

  private let transport: any BaiduHTTPTransport

  init(transport: any BaiduHTTPTransport = URLSessionBaiduHTTPTransport()) {
    self.transport = transport
  }

  func resolveAccountIdentity(accessToken: BaiduAccessToken) async throws
    -> BaiduAccountIdentity
  {
    try Task.checkCancellation()
    let request = try makeRequest(accessToken: accessToken)
    let response: BaiduHTTPResponse
    do {
      response = try await transport.send(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as BaiduHTTPTransportError {
      switch error {
      case .invalidResponse:
        throw BaiduNetdiskAccountResolutionError.invalidHTTPResponse
      case .responseTooLarge(let maximum):
        throw BaiduNetdiskAccountResolutionError.responseTooLarge(maximum: maximum)
      case .network, .unavailable:
        throw BaiduNetdiskAccountResolutionError.transport
      }
    } catch {
      throw BaiduNetdiskAccountResolutionError.transport
    }

    try Task.checkCancellation()
    guard (200..<300).contains(response.statusCode) else {
      throw BaiduNetdiskAccountResolutionError.httpStatus(response.statusCode)
    }
    guard response.body.count <= Self.maximumJSONResponseByteCount else {
      throw BaiduNetdiskAccountResolutionError.responseTooLarge(
        maximum: Self.maximumJSONResponseByteCount
      )
    }

    let decoded: UInfoResponse
    do {
      decoded = try JSONDecoder().decode(UInfoResponse.self, from: response.body)
    } catch {
      throw BaiduNetdiskAccountResolutionError.malformedResponse
    }
    guard let errno = decoded.errno else {
      throw BaiduNetdiskAccountResolutionError.malformedResponse
    }
    guard errno == 0 else {
      throw BaiduNetdiskAccountResolutionError.api(errno)
    }
    guard let uk = decoded.uk, let identity = BaiduAccountIdentity(uk: uk) else {
      throw BaiduNetdiskAccountResolutionError.invalidAccountIdentity
    }
    return identity
  }

  private func makeRequest(accessToken: BaiduAccessToken) throws -> URLRequest {
    guard
      var components = URLComponents(
        url: Self.endpoint,
        resolvingAgainstBaseURL: false
      )
    else {
      throw BaiduNetdiskAccountResolutionError.requestEncoding
    }
    components.queryItems = [
      URLQueryItem(name: "method", value: "uinfo"),
      URLQueryItem(name: "vip_version", value: "v2"),
      URLQueryItem(name: "access_token", value: accessToken.requestValue),
    ]
    guard let url = components.url else {
      throw BaiduNetdiskAccountResolutionError.requestEncoding
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 30
    )
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    return request
  }
}

private struct UInfoResponse: Decodable {
  let errno: Int?
  let uk: Int64?
}
