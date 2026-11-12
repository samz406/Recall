# Recall privacy and data boundaries

Updated November 2, 2026. Recall saves explicitly selected moments locally. It does not record audio or continuously capture your screen. Optional Enter monitoring and background text understanding are separate, off-by-default features.

## Recording and local storage

Before taking a screenshot, Recall checks pause settings, excluded apps and rule restrictions. It fixes the intended app/window or display, and fails rather than capturing a different app when that target disappears. Permission is checked again before saving. Screen capture uses ScreenCaptureKit; OCR uses Apple Vision on this Mac. A system permission name containing “System Audio” does not mean Recall records audio.

Records, optional screenshots, OCR, local search indexes, conversations and reviews live in Application Support/Recall. Original text is separate from normalized speaker information. Imported meeting notes are reference material, not your personal promises. A chat identity applies only to the app/window you explicitly confirm and can be revoked.

API Keys are stored in the macOS login Keychain through SecItem, without iCloud synchronisation. State files, new backups, exports and logs do not encode Keys. Legacy plaintext credentials are migrated before the old field is removed; failures preserve the original disk file and expose a retry in Settings. The archive is read-only while a credential migration is pending. Cleanup covers application-managed backups, not arbitrary copies, Time Machine or disk history. Keychain protection does not mean the entire screenshot/text archive is encrypted by Recall.

## Optional model requests

Cloud text use is off by default. After you connect a provider and allow it, AI features may send task-relevant, basically redacted text: questions and retrieved excerpts for Ask, selected-period material for reviews, opted-in record understanding, correction feedback, or manually requested action discovery. Connection testing sends no saved memory. Reusing a Daily Review to propose an action makes no extra model request.

Period reviews send the complete valid daily items and quotes within the selected dates and any explicit topic scope, including work, personal and learning content. The model classifies and summarizes them for the chosen output template; historical category labels do not filter input. Deleted, invalidated and privacy-excluded sources are removed, text is redacted, and screenshots are not sent by this review flow.

These text features do not upload screenshots. The API Key is used to authenticate with your configured API service, never included in model prompts or diagnostic logs. Changing the server host requires entering the credential for that host again. Redaction is an extra safeguard, not a guarantee that every sensitive item is removed. Provider retention and training policies depend on the provider and account you choose; Recall cannot promise a universal third-party training opt-out. This feature set adds no remote content telemetry or model-training collection.

## Actions, deletion and export

Proposed actions need confirmation. Add to Today creates an action without a notification; scheduling a notification separately requires a time you choose and system permission. Deleting sources withdraws unconfirmed derived suggestions. A user-accepted Today action keeps the user's intent but loses deleted source links and proof.

Deleted records can be restored for 7 days, then become ineligible for recovery. Cleanup runs while Recall is open or at its next launch. Meeting records and imported notes can be deleted and restored together. Export validates live evidence versions and excludes screenshot files, credentials and local file paths. A recall:// link is local, not a publicly accessible citation. Clipboard tools or the OS may sync copied data, and exported copies cannot be recalled by deleting the original.

## Read-only agent access

The local stdio MCP service is off by default. You choose a client label, date range, applications and whether reviews are allowed. A capability token grants access; the client label is not binary identity verification. Share the configuration only with a trusted local client. Revocation applies on its next request.

There is no network listener, write tool, screenshot tool or credential tool. Searches and excerpts are bounded and checked against the current archive on every request. The receiving agent may forward excerpts to its own model. A bounded local access log records timestamps and tool names, not queries, content or tokens.

## Samples and diagnostics

The sample uses synthetic in-memory records and prebuilt answers, never your private archive, a live model, real notifications or personalisation. Diagnostic logs contain safe operation states, error categories and counts. They exclude OCR, conversations, screenshots and credentials.

Signing, downloadable installers and automatic updates are outside this development scope.

## Archive reliability and retention

Recall keeps one checksum-validated local mirror of the current state, without API keys or screenshot copies. A corrupt primary opens a recovery screen rather than blank memory. Recovery is explicit and isolates the damaged bytes first. The mirror is not version history or protection against loss of the whole disk. Managed legacy copies and damaged archives are removed when content is withdrawn; file cleanup failures are queued, visible and retried. Copies you make yourself, OS backups, clipboard and exported data remain outside that cleanup boundary.

Ordinary text defaults to 90 days, screenshots to 7 days. Record management controls the periods. A record-detail switch can keep important text indefinitely without retaining its screenshots indefinitely. Explicit deletion overrides this switch.

Cloud Ask drafts receive a separate bounded verification request using already authorised text. Unsupported claims are omitted independently; verification failures show source excerpts instead of unverified drafts. No usable evidence means a local explanation, not a model-created factual answer. Model and OCR accuracy remain imperfect.

## Personal memory and topic summaries

About me supports explicit remember, edit, pause, resume and stop-use commands. Stopping use does not delete source records or saved reviews; source deletion remains a separate record-management action. Personal context is scoped to the current task and can be inspected and changed.

Automatic model topic summaries are a separate opt-in setting, off by default. They require an enabled model connection and permission to send redacted text. Only the changed topic's reviewed text is sent, with at most three topic updates per maintenance cycle. Saved content remains readable while updating or after failure. Pausing, cancellation, source changes and privacy changes prevent late results from committing. Local topic reading requires no model request.
