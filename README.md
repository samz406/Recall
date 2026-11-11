# Recall

[简体中文](README.zh-Hans.md)

**Your private work ledger.**

Recall shows where yesterday's work stopped, what to pick up today, and which saved record an answer came from. You decide when a moment is worth keeping. The record stays on your Mac.

Connect moments you chose to save into a searchable history of your work.

Core workflows support English and Simplified Chinese. See [workflow guide](docs/work-ledger-usage.md).

Memory has two reading areas: **Topics** for ongoing context and past decisions, and **About me** for background and preferences used in relevant answers. The sidebar **Reviews** entry brings daily and weekly/monthly reviews together.

## Quick start

There is no signed download and no App Store listing. Build Recall from this repository on your Mac.

You need macOS 14 or later and Swift 6. Full Xcode is the right tool for running and debugging the app. Xcode Command Line Tools are enough to compile the core and run the offline verifier.

```bash
git clone https://github.com/samz406/Recall.git
cd Recall
swift build --jobs 1
./scripts/run-app.sh
```

The script builds Recall and opens a development `Recall.app`. Use that app. Local notifications are delivered only from this bundle.

Before the first screenshot, allow Recall in **System Settings → Privacy & Security → Screen & System Audio Recording**. Recall asks for the screen when you record a moment, or when an event template you enabled fires. macOS asks for notification permission when you create your first reminder.

## Core loop

Three actions cover the first week.

### Record this moment

Press **⌃⌥⌘R** in your working app, or choose **Record a moment** in the menu bar. This saves one record of the current window: a single screenshot, then on-device OCR (Apple Vision) for Chinese and English. Time, source app, text, and the image go to `~/Library/Application Support/Recall/`. The same menu can pause screen capture. Customize shortcuts in Settings → Preferences; Recall must be running.

In **Recording** you can switch that rule to the current display or to text only (no screenshot). Other templates live there too. Recording when you press Enter in another app stays off until you enable it.

### Daily review

Open **Daily Review** and generate a review for a chosen day. Yesterday is the default. The review reads records already saved and does not take a new screenshot. When the material supports it, three sections appear:

- **Progress** — what moved forward
- **Next actions** — what to handle next
- **Worth noticing** — what deserves attention

A section with nothing reliable behind it stays hidden. A full daily review needs a model connection you configure, plus permission to send redacted text. Saved records stay in **Timeline** either way. **Add to Today** accepts a proposed action without scheduling a notification; **Remind me** separately asks you to choose a time.

### Ask

Open **Ask Recall** or press **⌃⌥⌘A**. Each answer cites local records, and you can open those sources. With cloud text off, Recall searches on this Mac and returns a traceable summary, without a network request. With cloud text on, the request carries the current question, retrieved excerpts, a rolling summary, and the recent message window, after basic redaction. Screenshot files stay on the Mac. Copy with sources or export Markdown from an answer; source versions are checked again before export.

## Privacy snapshot

- **Local-first.** Screenshots, OCR, the SQLite index, and chat history stay in `~/Library/Application Support/Recall/`. Search and storage work offline. You can pause capture, stop saving original screenshots, and exclude apps by bundle ID.
- **Explicit trigger.** A record starts when you trigger it. Continuous screenshots, scheduled screenshots, audio recording, and automatic message collection stay off. Enter-key capture in other apps stays off until you enable it, can be paused, and does not run while Recall is frontmost.
- **Deletable and traceable.** Delete a record and restore it from **Recently Deleted** for 7 days, or clear local memory. Dependent reviews and unconfirmed suggestions are withdrawn. User-accepted Today actions keep your intent without the deleted proof.
- **Cloud is opt-in.** Connect an OpenAI-compatible or Anthropic-compatible API with your own key, or leave cloud text off. The key is stored in the macOS Keychain, not in `recall-state.json`. It is not written to logs or committed to this repository. A reminder is scheduled only after you confirm it. Recall does not send messages, create calendar events, or edit your files.

The full boundary is in [Privacy and data boundaries](docs/PRIVACY.en.md). The [workflow guide](docs/work-ledger-usage.md) covers local samples, first records, meeting notes, identity confirmation and optional read-only MCP. See the [acceptance report](docs/international-workflow-acceptance.md) for verified behavior and manual checks. Signing, downloads and automatic updates remain outside this change.

## Roadmap

Planned, and not in this tree yet:

- Optional vector search
- End-to-end encrypted sync
- Finer exclusion of sensitive pages
- An accessibility audit

## Go deeper

Themes, weekly reviews, theme merging, reminders, habit learning, and the verifier are documented separately. These files are in Chinese.

- [Detailed behavior](docs/product-behavior.zh-Hans.md) — the spec this page used to contain
- [Architecture and verifier](docs/ARCHITECTURE.md)
- [Privacy design](docs/PRIVACY.md)
- [Personal intelligence](docs/PERSONAL_INTELLIGENCE.md) — episodes, insight feedback, habit candidates
- [Memory architecture](docs/memory-architecture.md) — themes, commitments, corrections, forgetting
- [Product experience](docs/product-experience.md) — daily and weekly reviews, theme merge, search
- [Page layout](docs/page-redesign.md)
- [Model API compatibility](docs/API_COMPATIBILITY.md)

## Stack and license

Swift 6 · macOS 14+ · on-device OCR (Vision) · SQLite (WAL + FTS5) · optional bring-your-own model key

[MIT License](LICENSE)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md). Check core logic with:

```bash
swift build --jobs 1
swift run RecallVerifier
```

The verifier uses no network, no real screenshots, and no real API keys. Permission prompts, live capture, OCR, notifications, and the menu bar still need a Mac with full Xcode.
