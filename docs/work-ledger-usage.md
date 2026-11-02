# Work-ledger workflows

This change implements the international workflow plan except distribution packaging, signing/notarization and automatic updates.

- **Preferences:** Settings → Preferences (设置 → 使用偏好). Choose English, Chinese or System, and a separate language for new reviews. Saved quotes are never translated.
- **Record:** default ⌃⌥⌘R, customizable in Preferences. ⌃⌥⌘A opens Ask. Registering these combinations does not turn on Enter monitoring. Recall must be running. If registration fails, choose a different combination and test it in your usual apps.
- **First use:** Try a sample is local and synthetic. Write my first record saves your own text without screen permission. Actual AI reviews still need your connected provider and text permission.
- **Today:** Add to Today accepts a proposed action without inventing a due time or asking for notification permission. Undo is available; Remind me separately schedules a notification.
- **Ask:** Copy with sources and Export Markdown validate sources again and include readable answer-level provenance. They do not imply sentence-by-sentence verification. Local file paths are omitted.
- **Chat identity:** select a saved Slack/Teams app/window and confirm your exact visible sender name. Unknown/duplicate identities stay unknown. Revocation invalidates dependent interpretations; regenerate affected reviews.
- **Meeting moments:** switch to your meeting window, return to Preferences, inspect Capture target, then Start & save. Finish & save takes another explicit frame. Paste/import UTF-8 .txt/.md notes as reference material, optionally linking their meeting and original date. No audio, bot or account integration. Delete a meeting's records as one group; 7-day recovery includes its grouping.
- **Credentials:** a saved credential is reused without displaying it. New values go to Keychain, not the state file. Delete credential revokes the local saved key. Retry migration/cleanup in Preferences if Keychain is unavailable. A downgrade may require reconnecting the model; older applications cannot safely read the new planned action state.

## Local stdio MCP

1. Build with the existing SwiftPM workflow: `swift build --product recall-cli`.
2. In Preferences, enter the exact `clientInfo.name` used by your MCP client, select dates, an application or all eligible sources, and review access.
3. Authorize and choose Copy connection config. Select your actual compiled `recall-cli` executable. The copied configuration contains a token; share it only with the chosen local client.
4. Start the MCP client. The command runs `recall-cli mcp --data-dir …` with `RECALL_MCP_TOKEN` in its environment. Do not put the token in command arguments or logs.
5. Available tools: `search_records`, `get_record_excerpt`, and (if authorized) `get_daily_review`. Requests outside the grant, deleted sources and revoked grants are denied. Tools cannot write memory, schedule notifications, load images or access API credentials.
6. Revoke access in Preferences. An already-running server checks the current file and denies its next request.

The protocol is JSON-RPC over newline-delimited UTF-8 stdio, with initialize → notifications/initialized → tools/list or tools/call. No HTTP listener is started. Agent access may allow excerpts to reach the agent's model, even though Recall's server is read-only.

## Compatibility boundaries

Slack channel extraction and Teams header grouping use visible text. Mail extraction trims leading chrome only when recognizable From/To/Subject/Date-style headers provide enough anchors. Unknown layouts retain their text as reference/unknown. Gmail, Outlook, Notion, Linear and Zoom can be explicitly recorded; this is not a claim of account synchronization or complete visibility of off-screen content. Real application versions, custom themes, keyboards, screen permissions and Keychain ACL prompts still require manual testing.
