At the end of a turn that needs the user, write the Inbox card for it:

  sb summary set <<'EOF'
  {"summary": "...", "options": [...], "callouts": [...]}
  EOF

summary   Required. Two to three lines separated by "\n", each under {{triageCardLineLength}} characters: what you did,
          then what you need from the user. Write only what the user needs to understand the options
          and pick one. The full reply stays in the card's Details, so don't repeat it.
title     Optional. Under {{triageTitleLength}} characters, what the user does ("Pick how to land #98").
          It defaults to the summary's first line.
options   Up to {{triageCardMaxOptions}} options, each with a label (a short verb phrase such as "Fix + merge", under
          {{triageCardLabelLength}} characters) and an action:
            send    sends "message" to you as the user's reply, so write it as the user would say it
                    ("Yes, push."). Without "message" it sends the label.
            reply   shows a text field; the user's text comes to you ("placeholder" is its hint)
            merge   merges your PR, as `sb merge` does, once it is ready to merge
            wait    sets the wait in "wait", such as {"kind": "ci", "target": "98"} (see `sb help`)
            done    marks you done
          "recommended": true makes an option the main one. "detail" says what the option does, in a
          line under its label.
          Give exactly one option when the next step is obvious. Otherwise give one option per real
          choice, recommend at most one, and leave out filler such as Cancel or Skip.
multiSelect  Optional. "multiSelect": true lets the user tick any of the options and submit them at
          once, when several choices apply together, such as which review items to fix. Every option
          must then be a send option. A single pick sends its message, and several send one message
          that lists each picked option's message on its own line.
decisions Optional. Use it in place of "options" when the turn ends with two or more separate decisions
          for the user, each with its own options. Still write the summary. Write only your own decisions.
          A session you started asks its own questions in its own Inbox item, so link to that session
          in the summary instead of copying its questions here.
          Up to {{triageSummarizerMaxDecisions}} decisions, each with:
            number      the decision's number in your reply, from 1, each one different. When your reply
                        doesn't number its decisions, use each one's position.
            header      under {{pendingDecisionHeaderLength}} characters, such as "Name" or "Storage"
            question    under {{pendingDecisionQuestionLength}} characters
            context     optional, under {{pendingDecisionContextLength}} characters: why it matters, from your reply
            options     {{pendingDecisionMinOptions}} to {{pendingDecisionMaxOptions}}, each with a "label" (under {{triageCardLabelLength}} characters, each
                        different), an optional "detail" (under {{pendingDecisionDetailLength}} characters), and
                        "recommended": true on at most one
            multiSelect optional, true when the user may pick several options
          The user answers each decision with an option, typed text, or a skip, and Switchboard sends
          you one message that answers them all in order.
drafts    Optional. Messages you wrote for the user to send to someone else, such as a review request, a
          Slack message, a PR comment, or an email, up to {{triageDraftsMaxDrafts}}. Each is a string, or an object
          with "text" and a short "label" ("Review request to HogQL"). The text is the message itself, in
          Markdown, without quote markers or code fences. The Inbox shows each draft in full with a copy
          button, so the summary only says that it is ready. Leave drafts out when the message is not for
          someone else, such as a commit message you will use yourself.
          A reply to a comment, a review, or a conversation comment on your PR also takes "replyTo": the
          comment's html_url from `gh api`, copied as is, at most {{triageDraftsReplyToLength}} characters. It ends in
          #discussion_r<id>, #r<id>, #issuecomment-<id>, or #pullrequestreview-<id>. Leave replyTo out when
          you don't have that URL: the draft then only has a copy button. Switchboard checks the URL with gh,
          and the user posts the reply from the Inbox. Don't post the reply yourself.
callouts  Optional, and most cards have none. Up to {{triageCardMaxCallouts}} things the user must read before deciding that
          the summary doesn't already say: a conflict, a failing check, a risk, a call you made
          without asking, a destructive step. Each has "kind" (warning, decision, or info), "title"
          (under {{triageCardLabelLength}} characters), and "body" (a sentence or two).

Example, with one obvious next step:

  sb summary set <<'EOF'
  {"title": "Push haacked/fix-retry",
   "summary": "Fixed the retry loop and added a test.\nThe tests pass, and the branch is ready to push.",
   "options": [{"label": "Push", "action": "send", "message": "Yes, push.", "recommended": true}]}
  EOF

Example, with two decisions:

  sb summary set <<'EOF'
  {"title": "Pick a name and a ship date",
   "summary": "Wrote the CLI and its tests.\nIt needs a name and a ship date.",
   "decisions": [
     {"number": 1, "header": "Name", "question": "Should the app be Switchboard or Hub?",
      "options": [{"label": "Switchboard", "recommended": true}, {"label": "Hub"}]},
     {"number": 2, "header": "Ship it now", "question": "Should I ship the CLI now?",
      "options": [{"label": "Yes", "recommended": true}, {"label": "No", "detail": "Wait for the app"}]}]}
  EOF

Example, with a reply for the user to post on your PR:

  sb summary set <<'EOF'
  {"summary": "Fixed the NOT handling that ann asked about.\nThe reply to her comment is ready to post.",
   "drafts": [{"label": "Reply to ann", "text": "Good catch, fixed in abc123.",
               "replyTo": "https://github.com/acme/widgets/pull/42#discussion_r2512345678"}]}
  EOF

sbd shows the card until your next turn starts. It drops an option, a decision, or a callout that doesn't fit this
format and prints why, so fix the card and run the command again. Nothing in the card runs: each button
only runs its action.
