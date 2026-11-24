/// An immutable value on the heap. A struct that holds a `Box` stores one pointer in the value's place. It encodes
/// and decodes as the value itself.
@dynamicMemberLookup
public struct Box<Value: Sendable>: Sendable {
  private final class Storage: Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
  }

  private let storage: Storage

  public init(_ value: Value) { storage = Storage(value) }

  public var value: Value { storage.value }

  public subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> T { storage.value[keyPath: keyPath] }
}

extension Box: Equatable where Value: Equatable {
  public static func == (lhs: Box, rhs: Box) -> Bool { lhs.storage === rhs.storage || lhs.value == rhs.value }
}

extension Box: Encodable where Value: Encodable {
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(value)
  }
}

extension Box: Decodable where Value: Decodable {
  public init(from decoder: Decoder) throws {
    self.init(try decoder.singleValueContainer().decode(Value.self))
  }
}
