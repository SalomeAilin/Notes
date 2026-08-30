struct BaiduAccountIdentity: Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  private let value: Int64

  init?(uk: Int64) {
    guard uk > 0 else { return nil }
    value = uk
  }

  var description: String { "<redacted>" }
  var debugDescription: String { "<redacted>" }
  var customMirror: Mirror {
    Mirror(self, children: EmptyCollection<Mirror.Child>())
  }
}
