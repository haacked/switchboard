import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct JSONParseTests {
  @Test func parsesDataLikeItsText() {
    let text = #"{"a":[1,"b",null]}"#
    #expect(JSON.parse(Data(text.utf8)) == ["a": [1, "b", .null]])
  }

  @Test func replacesInvalidUTF8() {
    let data = Data([0x22, 0xFF, 0x22])
    #expect(JSON.parse(data) == .string("\u{FFFD}"))
  }

  @Test func returnsNilForDataThatIsNotJSON() {
    #expect(JSON.parse(Data("not json".utf8)) == nil)
  }
}
