#!/bin/sh
# A stand-in for the sb CLI, for Phase 0 test 4. Only `sb ask` exists.
# `sb ask <question> [option]...` appends the question, its options, and
# $SB_SESSION_ID to $SB_HOME/questions.jsonl as one JSON line, and returns at once.
if [ "${1:-}" != ask ] || [ $# -lt 2 ]; then
  echo "usage: sb ask <question> [option]..." >&2
  exit 2
fi
shift
if ! jq -nc --arg s "${SB_SESSION_ID:-}" \
  '{session: $s, question: $ARGS.positional[0], options: $ARGS.positional[1:]}' \
  --args -- "$@" >>"${SB_HOME:?}/questions.jsonl"; then
  echo "sb: could not record the question" >&2
  exit 1
fi
echo "Switchboard shows your question to the user. End your turn now. The answer arrives as your next message."
