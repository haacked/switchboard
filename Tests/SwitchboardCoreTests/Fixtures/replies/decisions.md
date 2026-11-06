Decisions I need from you:

1. **Should a due follow-up move the session to Needs you?** I recommend yes. That adds 1 to the badge and sends one notification for each follow-up you asked for, at the moment it's due. The catch is that the session leaves the Done column while the follow-up is due, so you delete it from the Inbox card's "Resolve and Delete…" instead of the trash button. The alternatives are a quieter Inbox section that the badge doesn't count (it needs a new state and Board column) or the icon alone.
2. **Name.** "Follow-up" already means `sb followup` and your `/followup` list. I recommend "to-do" (`sb note --todo`). The other choice is to keep "follow-up note" (`sb note --followup`).
3. **Where the resolution record lives.** I recommend a new table in sbd's database. The alternatives are a line in `sbd.log` or a checked line in `Followups.md`.
4. **Follow-ups on groups.** I recommend refusing them for now. Allowing them means `sb group rm` needs the same block.
5. **Show the icon for plain notes too?** I recommend yes, dimmed. The other choice is to show it only for follow-ups, which keeps tiles quieter, since the Manager and group chats also write notes.
6. **Should a Stale session bring up its follow-up?** I recommend no. The icon still shows.

The plan also covers two other designs and why I don't recommend them, the tests for each safety condition, and the cost of each slice.
