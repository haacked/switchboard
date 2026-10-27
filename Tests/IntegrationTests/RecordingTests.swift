import Foundation
import SwitchboardCore
import Testing

@Suite struct RecordingTests {
  let context = Recording.Context(
    cwd: ["/tmp/sbt.abc/work", "/private/tmp/sbt.abc/work"], home: "/Users/me", nonce: "SB123",
    prompts: ["Run it and reply with SB123."], commands: ["./slow.sh 4"])

  func payload(_ fields: [String: JSON]) -> JSON {
    .object(
      [
        "session_id": "uuid-1", "cwd": "/private/tmp/sbt.abc/work",
        "transcript_path": "/Users/me/.claude-personal/projects/-private-tmp-sbt-abc-work/uuid-1.jsonl",
        "scratchpad_dir": "/private/tmp/claude-501/-private-tmp-sbt-abc-work/uuid-1/scratchpad",
      ].merging(fields) { $1 })
  }

  @Test func replacesTheRunsPathsAndSessionIds() {
    let out = Recording.normalize([payload(["hook_event_name": "SessionStart", "source": "startup"])], context)
    #expect(
      out == [
        [
          "session_id": "{{session_id}}", "cwd": "{{cwd}}", "hook_event_name": "SessionStart", "source": "startup",
          "transcript_path": "{{config_dir}}/projects/{{encoded_cwd}}/{{session_id}}.jsonl",
          "scratchpad_dir": "{{claude_tmp}}/{{encoded_cwd}}/{{session_id}}/scratchpad",
        ]
      ])
  }

  @Test func numbersEachSessionIdAfterTheFirst() {
    let out = Recording.normalize(
      [
        payload(["hook_event_name": "SessionEnd", "reason": "clear"]),
        payload(["hook_event_name": "SessionStart", "session_id": "uuid-2"]),
      ], context)
    #expect(out.map { $0["session_id"] } == ["{{session_id}}", "{{session_id_2}}"])
  }

  @Test func replacesTheTestsPromptsCommandsAndNonce() {
    let out = Recording.normalize(
      [
        payload(["hook_event_name": "UserPromptSubmit", "prompt": "Run it and reply with SB123."]),
        payload([
          "hook_event_name": "PreToolUse", "tool_input": ["command": "./slow.sh 4", "description": "Wait a while"],
        ]),
        payload(["hook_event_name": "UserPromptSubmit", "prompt": "<summary>Wait a while is done: SB123</summary>"]),
      ], context)
    #expect(out[0]["prompt"] == "{{prompt}}")
    #expect(out[1]["tool_input"] == ["command": "{{command}}", "description": "{{description}}"])
    #expect(out[2]["prompt"] == "<summary>{{description}} is done: {{nonce}}</summary>")
  }

  @Test func replacesWhatTheModelWrote() {
    let out = Recording.normalize(
      [
        payload(["hook_event_name": "Stop", "last_assistant_message": "All done.", "stop_hook_active": false]),
        payload([
          "hook_event_name": "PreToolUse", "tool_input": ["prompt": "Reply with SB123 only.", "subagent_type": "x"],
        ]),
        payload([
          "hook_event_name": "UserPromptSubmit",
          "prompt": "<task-notification>\n<result>It ran.\nNo output.</result>\n</task-notification>",
        ]),
      ], context)
    #expect(out[0]["last_assistant_message"] == "{{reply}}")
    #expect(out[0]["stop_hook_active"] == false)
    #expect(out[1]["tool_input"] == ["prompt": "{{agent_prompt}}", "subagent_type": "x"])
    #expect(out[2]["prompt"] == "<task-notification>\n<result>{{result}}</result>\n</task-notification>")
  }

  @Test func zeroesDurationsCountsAndCosts() {
    let out = Recording.normalize(
      [
        payload(["hook_event_name": "SessionStart", "context_tokens": 49606, "estimated_cache_write_usd": 0.0099]),
        payload([
          "hook_event_name": "UserPromptSubmit",
          "prompt": "<status>completed</status>\n<usage><subagent_tokens>31456</subagent_tokens></usage> (exit code 1)",
        ]),
      ], context)
    #expect(out[0]["context_tokens"] == 0)
    #expect(out[0]["estimated_cache_write_usd"] == 0)
    #expect(
      out[1]["prompt"]
        == "<status>completed</status>\n<usage><subagent_tokens>0</subagent_tokens></usage> (exit code 1)")
  }

  @Test func numbersIdsInTheOrderTheyAppearWhereverTheyAppear() {
    let out = Recording.normalize(
      [
        payload(["hook_event_name": "PreToolUse", "tool_use_id": "toolu_A", "prompt_id": "p-1"]),
        payload([
          "hook_event_name": "PostToolUse", "tool_use_id": "toolu_A", "tool_response": ["backgroundTaskId": "bt9"],
        ]),
        payload(["hook_event_name": "PreToolUse", "tool_use_id": "toolu_B", "agent_id": "ag7"]),
        payload([
          "hook_event_name": "Stop", "background_tasks": [["id": "bt9", "status": "running"]],
          "agent_transcript_path": "/x/agent-ag7.jsonl",
        ]),
        payload(["hook_event_name": "UserPromptSubmit", "prompt": "<task-id>bt9</task-id><tool-use-id>toolu_A"]),
      ], context)
    #expect(out[0]["tool_use_id"] == "{{tool_use_id_1}}")
    #expect(out[0]["prompt_id"] == "{{prompt_id_1}}")
    #expect(out[1]["tool_response"] == ["backgroundTaskId": "{{task_id_1}}"])
    #expect(out[2]["tool_use_id"] == "{{tool_use_id_2}}")
    #expect(out[3]["background_tasks"] == [["id": "{{task_id_1}}", "status": "running"]])
    #expect(out[3]["agent_transcript_path"] == "/x/agent-{{agent_id_1}}.jsonl")
    #expect(out[4]["prompt"] == "<task-id>{{task_id_1}}</task-id><tool-use-id>{{tool_use_id_1}}")
  }

  @Test func readsAndWritesOnePayloadPerLine() throws {
    var template = Array("/tmp/sbr.XXXXXX".utf8CString)
    let dir = String(cString: try #require(mkdtemp(&template)))
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let payloads: [JSON] = [["hook_event_name": "Stop", "b": true, "a": "x/y"], ["hook_event_name": "SubagentStop"]]
    try Recording.write(payloads, to: "\(dir)/turn.jsonl")
    #expect(
      try String(contentsOfFile: "\(dir)/turn.jsonl", encoding: .utf8)
        == "{\"a\":\"x/y\",\"b\":true,\"hook_event_name\":\"Stop\"}\n{\"hook_event_name\":\"SubagentStop\"}\n")
    #expect(try Recording.read("\(dir)/turn.jsonl") == payloads)
  }
}
