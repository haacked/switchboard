import Testing

@testable import SwitchboardCore

@Suite struct ChatMessageTests {
  // MARK: isNotice

  @Test(
    arguments: [
      (ChatMessage.Role.user, "Switchboard: posthog-123 needs you.", true),
      (.user, "Switchboard:", true),
      (.user, "Note from Switchboard: posthog-123 needs you.", false),
      (.user, "switchboard: posthog-123 needs you.", false),
      (.user, "Switchboard posthog-123 needs you.", false),
      (.assistant, "Switchboard: posthog-123 needs you.", false),
    ] as [(ChatMessage.Role, String, Bool)])
  func aNoticeIsAUserMessageThatStartsWithTheSwitchboardPrefix(_ role: ChatMessage.Role, _ text: String, _ notice: Bool)
  {
    #expect(ChatMessage(role: role, text: text).isNotice == notice)
  }

  // MARK: slashCommand

  /// The transcript writes the message element before the name element.
  @Test func aCommandWithTheMessageFirstReadsAsItsNameAndArgs() {
    let args = "the dropdown doesn't show clearly what the current account is. Make that clear."
    let text =
      "<command-message>spawn-task</command-message>\n<command-name>/spawn-task</command-name>\n<command-args>\(args)</command-args>"

    #expect(ChatMessage(role: .user, text: text).slashCommand == "/spawn-task \(args)")
  }

  /// The transcript writes the name element first and indents the others.
  @Test func aCommandWithTheNameFirstAndEmptyArgsReadsAsItsName() {
    let text =
      "<command-name>/clear</command-name>\n            <command-message>clear</command-message>\n            <command-args></command-args>"

    #expect(ChatMessage(role: .user, text: text).slashCommand == "/clear")
  }

  @Test func aCommandWithNoArgsElementReadsAsItsName() {
    let text = "<command-message>clear</command-message>\n<command-name>/clear</command-name>"

    #expect(ChatMessage(role: .user, text: text).slashCommand == "/clear")
  }

  @Test func aCommandWhoseArgsAreOnlyWhitespaceReadsAsItsName() {
    let text = "<command-name>/clear</command-name>\n<command-args>  \n  </command-args>"

    #expect(ChatMessage(role: .user, text: text).slashCommand == "/clear")
  }

  @Test func aCommandsArgsLoseTheirOuterWhitespaceAndKeepTheirInnerNewline() {
    let text = "<command-name>/review</command-name>\n<command-args>\n  first line\nsecond line  \n</command-args>"

    #expect(ChatMessage(role: .user, text: text).slashCommand == "/review first line\nsecond line")
  }

  @Test func aNameElementInsideTheArgsDoesNotReplaceTheCommandsName() {
    let text =
      "<command-args>why does <command-name>/x</command-name> show?</command-args>\n<command-name>/ask</command-name>"

    #expect(ChatMessage(role: .user, text: text).slashCommand == "/ask why does <command-name>/x</command-name> show?")
  }

  @Test func aCommandAfterLeadingWhitespaceStillReadsAsACommand() {
    let text = "\n  <command-name>/clear</command-name>\n<command-args></command-args>"

    #expect(ChatMessage(role: .user, text: text).slashCommand == "/clear")
  }

  /// The rewrite applies only to a user message whose trimmed text starts with `<command-` and holds a
  /// closed name element. Each of these breaks one of those conditions.
  @Test(
    arguments: [
      (ChatMessage.Role.user, "Why does <command-name>/x</command-name> show up here?"),
      (.user, "I typed <command-name>/clear</command-name>\n<command-args></command-args>"),
      (.assistant, "<command-name>/clear</command-name>\n<command-args></command-args>"),
      (.assistant, "<command-message>spawn-task</command-message>\n<command-name>/spawn-task</command-name>"),
      (.user, "<command-name>/clear\n<command-args></command-args>"),
      (.user, "<command-name>/clear"),
      (.user, "<command-message>clear</command-message>\n<command-args>now</command-args>"),
      (.user, "Switchboard: posthog-123 needs you."),
      (.user, "Please run /clear for me."),
      (.user, ""),
    ] as [(ChatMessage.Role, String)])
  func aMessageThatIsNotACommandHasNoSlashCommand(_ role: ChatMessage.Role, _ text: String) {
    #expect(ChatMessage(role: role, text: text).slashCommand == nil)
  }
}
