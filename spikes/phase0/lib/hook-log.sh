#!/bin/sh
# A Claude Code command hook. Appends the hook payload to $SB_HOOK_LOG as one
# JSON line with a millisecond timestamp. It prints nothing, because Claude Code
# adds a SessionStart hook's stdout to the conversation.
jq -c '{t: (now * 1000 | floor), event: .hook_event_name} + .' >>"${SB_HOOK_LOG:?}" 2>/dev/null
exit 0
