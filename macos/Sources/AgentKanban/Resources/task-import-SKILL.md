---
name: task-import
description: Import a task spreadsheet or GitHub Issues into the current project's local board when the user explicitly requests it in a project conversation.
---

Bind the request to its original project, conversation and human message. Explicit requests include importing tasks and adding Issues to the board. Sources and instructions may arrive in separate messages; continue the latest uncommitted human request after a source or login follow-up. Cancellation, unrelated requests and successful commits end continuation. Never use assistant messages as authorization or sources, or treat an attachment or a link alone as permission to import.

Read .xlsx, .csv and .tsv attachments or github.com Issue links. A repository link denotes its Issues only with an explicit Issue import request. Preserve requested state, labels and assignee filters; resolve @me through the authenticated GitHub account. Reject ambiguous, conflicting or unsupported scopes instead of broadening them. Replacement sources supersede old sources. Normalize titles, multiline descriptions, task types and priorities. Report invalid rows and unavailable sources; missing sources do not create an empty committed batch.

The host ImportService commits valid records directly as backlog tasks using the project's default executor and native defaults. Deduplicate stable source keys in the project and the original request's operation key across retries. Retain source references and report the actual source scope, persisted task numbers, skipped duplicates and failures in the same conversation. A model reply or completed subagent is not proof of a committed import. Do not show a source chooser, preview wizard or extra confirmation. Never change task phases, execute code, alter source Issues, directly edit the database or create worktrees as part of an import.
