# pless — technical background

Internals for developers. The roadmap with phases & progress lives in
[implementierung.en.md](implementierung.en.md), the product description in the
[README](../README.en.md) (German) / [README](../README.md).

## Installation & release

**Release (end users):** download `Pless-macOS.zip` (+ `.sha256` for verification) from
[GitHub Releases](https://github.com/ptc/pless/releases/latest), unzip and copy `Pless.app`
to `/Applications`. The app is ad-hoc signed (no Apple certificate), so macOS reports
“Pless is damaged” on first launch — no actual damage, run once in Terminal:
`xattr -cr /Applications/Pless.app` (removes the quarantine attribute).

**Release process:** `.github/workflows/release.yml` — a tag push builds the bundle via
`Scripts/make-app.sh`, packs `dist/Pless-macOS.zip` + SHA-256 and publishes both as a
GitHub release (`gh release create` / `gh release upload --clobber`).

## Build, run & CLI

```bash
swift build --package-path /Users/ptc/dev/ppless
swift run   --package-path /Users/ptc/dev/ppless PlessTests                # tests (exit code 0 = green)
swift run   --package-path /Users/ptc/dev/ppless Pless                       # app (GUI)
swift run   --package-path /Users/ptc/dev/ppless Pless --vault <path>        # app with another vault
swift run   --package-path /Users/ptc/dev/ppless Pless mcp --vault <path>    # MCP server (stdio)
```

## Architecture

- **Swift 6, Swift Package Manager only** — no Xcode project, no external packages.
- Logic lives UI-free in `Sources/PlessCore` (fully testable without the app); `Sources/Pless`
  is only the app shell (`@main`) + CLI subcommands (`mcp`).
- **SQLite directly** via `import SQLite3` (FTS5 is included in the system SQLite);
  `pless.db` lives in the vault folder itself. Schema versions via `PRAGMA user_version`.
- **MCP** as a custom JSON-RPC 2.0 implementation over stdio (protocolVersion `2025-06-18`).
- System frameworks: AppKit, SwiftUI, PDFKit, Vision, CryptoKit.
- Tests: MiniTest runner (`swift run PlessTests`, exit code 0 = green) — the
  command-line toolchain ships neither XCTest nor Swift Testing macros.

## Vault layout

```
<vault>/                       default ~/Documents/Pless, changeable in settings
├── pless.db                   SQLite: metadata + FTS5 full-text index + sync_map
├── documents/YYYY/MM/…pdf     storage, file name from template {date}_{correspondent}_{title}.pdf
├── inbox/                     import folder (watcher via DispatchSource + poll fallback;
│   └── _abgelehnt/            duplicates & unreadable files   path optionally changeable)
└── thumbnails/                PNG cache (regenerable, format marker against orientation changes)
```

## Database schema & migrations

| Version | Contents |
|---|---|
| V1 | `documents`, `correspondents`, `categories`, `tags`, `document_tags` |
| V2 | FTS5 full-text index `documents_fts` (title, OCR text, correspondent) + triggers |
| V3 | `sync_map(document_id, paperless_id, sha256, synced_at)` — paperless mapping |
| V4 | `documents.sync_state` (`synced` / `not_synced` / `unknown`), backfill from `sync_map` |
| V5 | `sync_map.meta_sha256` — metadata hash at last push |

## Sync to paperless-ngx (opt-in, phase 13)

**Principle:** without a configured paperless URL + API token (UserDefaults + keychain,
not in `pless.db`) no network call is ever executed. “Test connection” = `GET /api/`.

- **Client:** `PaperlessClient` in PlessCore with injectable `HTTPTransport` protocol
  (app: URLSession, tests: fake). Find-or-create for correspondents / document types / tags
  (only an exact case-insensitive name match counts — never `results.first`, otherwise
  everything lands in the same category), `post_document` (multipart), checksum search, `ping`,
  paginated `listNamed` (follows `next`) for the pull, `updateDocument` (PATCH).
- **Push (one-way):** `SyncService` pushes all new/changed documents. Mapping:
  correspondent → correspondent, category → document type, tag → tag; PDF via
  `POST /api/documents/post_document/` with the vault file name (→ `original_filename`),
  title → `title`, date → `created`.
- **Idempotency:** `sync_map` + checksum check `GET /api/documents/?checksum=<sha256>`.
  File changed (new sha256) → re-upload; only metadata changed (`meta_sha256`
  differs) → `PATCH /api/documents/<id>/` (title/created only when set, otherwise 400;
  null references clear correspondent/document_type), no re-upload.
- **Forced sync:** `forceMetadata: true` (dropdown on the sync button / menu in the details)
  pushes metadata via PATCH even when the hash is unchanged — e.g. to correct a wrongly
  mapped category.
- **Pull (master data):** `pullMetadata()` imports all document types as categories
  and all correspondents as correspondents (paginated, case-insensitively idempotent).
- **Sync state per PDF:** `documents.sync_state` (V4) as a cloud badge on every card
  (top right) and in the details: `cloud.fill` green = synced, `cloud` orange =
  not_synced (also right after a metadata edit or a failed push), cloud + “?”
  grey = unknown (not configured / never run; `cloud.questionmark` does not exist
  in every SF Symbols catalog, hence composed).

## MCP protocol

`pless mcp --vault <path>`: JSON-RPC 2.0, one message per line (stdio).
Tools: `search_documents`, `get_document`, `list_documents`, `list_categories`,
`update_document` (incl. file rename), `assign_tag`, `get_stats`.
Errors as JSON-RPC errors (-32700/-32601/…), `notifications/initialized` without reply.

**Client config** (e.g. Claude Desktop; also copyable in the app settings under “MCP”):

```json
{
  "mcpServers": {
    "pless": {
      "command": "<path-to-binary>/Pless",
      "args": ["mcp", "--vault", "/Users/ptc/Documents/Pless"]
    }
  }
}
```

## Tests

MiniTest (own runner in `Sources/MiniTest`, registration in `Tests/PlessTests/AllTests.swift`).
Sync tests with a fake transport (find-or-create, multipart payload, idempotency via checksum,
PATCH, pull, error paths) — last run 96 tests green.

## App bundle & signing

`Scripts/make-app.sh` builds release + `dist/Pless.app` (ad-hoc signed via codesign,
icon from `docs/pless-app-icon-svg.svg` via `Scripts/make-icon-from-image.swift` + iconutil).
`dist/` is gitignored. Open: Developer-ID signing, share extension + app group
(needs an Xcode project).

## Legal & liability

- **Use at your own risk:** private project at an early stage (0.1.x), without any warranty —
  neither functionality nor data integrity. Back up the vault regularly (it is a plain folder,
  e.g. via Time Machine).
- pless is **not** affiliated with paperless-ngx and is not endorsed by it. “paperless” and
  “paperless-ngx” are trademarks of their respective organizations; pless is an independent
  project. The optional sync only uses the public API of paperless-ngx.
- License: **GPL-3.0-or-later** (see [LICENSE](../LICENSE)); forks are welcome, external
  commits/PRs are not accepted.

## Known limitations (technical)

- Share extension missing (see above); trash UI missing (soft delete `deleted_at`
  is prepared in the schema).
- Sync is a one-way push: changes made directly in paperless-ngx are not mirrored back
  into pless; a document deleted remotely is simply re-uploaded on the next sync.
- OCR: languages de/en (settings), accuracy/dpi/language-correction configurable (settings);
  Vision framework.
- Tests via MiniTest instead of XCTest/Swift Testing (CLT legacy).
