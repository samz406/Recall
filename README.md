# Recall

[简体中文](README.zh-Hans.md)

**A local-first, explicitly triggered work-experience ledger for Mac knowledge workers.**

Recall shows where yesterday's work stopped, what to pick up today, and which saved record an answer came from. You decide when a moment is worth keeping. The record stays on your Mac.

It keeps work you chose to save: not passive always-on screen recording (Limitless, Microsoft Recall), and not a generic second-brain notes app.

The app interface is Simplified Chinese.

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

In the menu bar, choose **记录此刻**. That click saves one record of the current window: a single screenshot, then on-device OCR (Apple Vision) for Chinese and English. Time, source app, text, and the image go to `~/Library/Application Support/Recall/`. The same menu can pause screen capture.

In **记录管理** you can switch that rule to the current display (**当前显示器**) or to text only (**仅文本**, no screenshot). Other templates live there too. Recording when you press Enter in another app stays off until you enable it.

### Daily review

Open **每日回顾** and generate a review for a chosen day. Yesterday is the default. The review reads records already saved and does not take a new screenshot. When the material supports it, three sections appear:

- **今天推进了什么** — what moved forward
- **接下来要处理** — what to handle next
- **值得留意** — what is worth noticing

A section with nothing reliable behind it stays hidden. A full daily review needs a model connection you configure, plus permission to send redacted text. Saved records stay in **时间线** either way.

### Ask

Open **问一问**. Each answer cites local records, and you can open those sources. With cloud text off, Recall searches on this Mac and returns a traceable summary, without a network request. With cloud text on, the request carries the current question, retrieved excerpts, a rolling summary, and the recent message window, after basic redaction. Screenshot files stay on the Mac.

## Privacy snapshot

- **Local-first.** Screenshots, OCR, the SQLite index, and chat history stay in `~/Library/Application Support/Recall/`. Search and storage work offline. You can pause capture, stop saving original screenshots, and exclude apps by bundle ID.
- **Explicit trigger.** A record starts when you trigger it. Continuous screenshots, scheduled screenshots, audio recording, and automatic message collection stay off. Enter-key capture in other apps stays off until you enable it, can be paused, and does not run while Recall is frontmost.
- **Deletable and traceable.** Delete a record and restore it from **最近删除** for 7 days, or clear local memory. Reviews and reminders that depended on a deleted record are removed with it. Answers keep their sources.
- **Cloud is opt-in.** Connect an OpenAI-compatible or Anthropic-compatible API with your own key, or leave cloud text off. The key is plain text in the local `recall-state.json`, not in the Keychain. It is not written to logs or committed to this repository. A reminder is scheduled only after you confirm it. Recall does not send messages, create calendar events, or edit your files.

The full boundary is in [Privacy design](docs/PRIVACY.md).

## Roadmap

Planned, and not in this tree yet:

- A real system-wide shortcut for recording
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
