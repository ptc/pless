# pless

<img src="docs/pless-app-icon-svg.svg" width="128" alt="pless icon">

Deutsch: [README.md](README.md)

Native macOS app for local document management — Paperless, but local & native:
import PDFs, index them with on-device OCR, store them in one place, search them,
and connect them to a local AI via **MCP**. No cloud, single user.

## Installation

Download `Pless-macOS.zip` from [Releases](https://github.com/ptc/pless/releases/latest) and unzip it.

**Note on the "Pless is damaged" message:** The app is signed without an Apple certificate, so macOS warns about it. No actual damage. Run once in Terminal:

```bash
xattr -cr /Applications/Pless.app
```

Build from source (Xcode installed, SwiftPM): `swift build --package-path /Users/ptc/dev/ppless`
— details on tests, app bundle and MCP server in [docs/technik.en.md](docs/technik.en.md).

## What pless can do

- **Import:** PDFs via drag & drop, via “File > Import…” or automatically from the inbox (`inbox/`); duplicates go to `_abgelehnt/`.
- **OCR & search:** text recognition directly on the Mac (Vision, de/en) and full-text search across title, OCR text and correspondent — all in one local database.
- **Storage & metadata:** PDFs land in `documents/YYYY/MM/` with names following a template (`{date}_{correspondent}_{title}.pdf`); edit title, date, correspondent, category, tags and notes in the app, plus thumbnails and a detail view.
- **Bilingual UI:** German and English, switchable in the settings.
- **AI connection:** own MCP server over stdio — a local AI can search/read documents, change metadata and assign tags.
- **paperless-ngx sync (opt-in):** push to a self-hosted paperless instance, including import of categories/correspondents and a sync indicator per PDF.

## Technical docs

Architecture, vault layout, database schema, sync design, MCP protocol, build & tests,
app bundle, known limitations: [docs/technik.en.md](docs/technik.en.md).
Roadmap & progress log: [docs/implementierung.en.md](docs/implementierung.en.md).

## License

pless is open source under **GPL-3.0-or-later** — see [LICENSE](LICENSE) (SPDX: `GPL-3.0-or-later`).
Forks are explicitly welcome. **Use at your own risk:** private project at an early stage
(0.1.x), provided without any warranty — back up your vault regularly.
