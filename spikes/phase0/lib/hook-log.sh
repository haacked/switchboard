#!/bin/sh
# A Claude Code command hook. Appends the hook payload to $SB_HOOK_LOG as one
# JSON line with a millisecond timestamp. It prints nothing, because Claude Code
# adds a SessionStart hook's stdout to the conversation.
# sb_env records which variables reach the hook. A background session's worker
# inherits only a few variables from the shell that started it.
jq -c '{t: (now * 1000 | floor), event: .hook_event_name,
  sb_env: {SB_SESSION_ID: env.SB_SESSION_ID, SB_PROBE: env.SB_PROBE,
    CLAUDE_CODE_MESSAGING_SOCKET: env.CLAUDE_CODE_MESSAGING_SOCKET, CLAUDE_JOB_DIR: env.CLAUDE_JOB_DIR}} + .' \
  >>"${SB_HOOK_LOG:?}" 2>/dev/null
exit 0
