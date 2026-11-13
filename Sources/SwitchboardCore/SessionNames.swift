/// How sbd names a session in text that a person or an agent reads. The id
/// stays because an agent needs it to run `sb` commands.
public func sessionMention(name: String, id: String) -> String { "\(name) (\(id))" }
