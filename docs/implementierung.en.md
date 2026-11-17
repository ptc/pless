# pless — implementation plan & progress

Native macOS app for local document management (Paperless, but local & native):
sort PDFs, index them with OCR, display them, store them in one place with sensible
file names, search them, and connect them to an AI via the open **MCP** standard.
No cloud, single user.

> English translation of [implementierung.md](implementierung.md). The progress log
> at the bottom quotes the original (German) commit messages verbatim.

## Fixed architecture decisions

| Topic | Decision | Rationale |
|---|---|---|
| Stack | Swift 6.4 + SwiftPM; Xcode 27.2 installed & active (full toolchain, no sudo) | `swift build` / `swift run` are enough; XCTest/Swift Testing optional later |
| Dependencies | no external packages | CLT/offline-safe; SQLite via `import SQLite3`, MCP implemented in-house |
| UI | SwiftUI + AppKit hybrid, pure code (no storyboards), SF Symbols, UI in German | modern, clean, dark mode included |
| Storage | one vault folder (default `~/Documents/Pless`), `pless.db` inside the vault | "one place", portable, all local |
| File names | template `{date}_{correspondent}_{title}.pdf`, sanitized, collision counter | human-readable & sortable |
| OCR | Apple Vision (`VNRecognizeTextRequest`), de+en, on-device | no cloud, system framework |
| Search | SQLite FTS5 over title + OCR text + metadata | local, fast, no dependency |
| AI connection | MCP (Model Context Protocol) as CLI subcommand `pless mcp` over stdio | open standard, local (e.g. Claude Desktop) |
| Storage copy | one canonical copy with a generated name (no original+archive duplicate) | "one place", tidy |
| Classification | **categories** (optional hierarchical, exactly one per document) + flat tags (many per document) + correspondents | categories for organizing, tags for marking |
| Import | import folder (watch) + drag & drop/file dialog + Apple share (share extension → app group → inbox/) | all paths lead into one pipeline |
| Tests | MiniTest (own runner in `Sources/MiniTest`, tests in `Tests/PlessTests`), exit code 0 before every commit | CLT ships neither XCTest nor Swift Testing macros; tests belong with the feature |
| Commits | small & frequent, Conventional Commits | iterative, traceable |

## Project layout

```
pless/
├── Package.swift
├── AGENTS.md                     ← process (binding)
├── docs/implementierung.md       ← this document (German): plan + progress
├── Sources/
│   ├── MiniTest/                 ← minimal test framework (CLT: no XCTest, no Testing macros)
│   ├── PlessCore/                ← model, vault, ingest, OCR, index (FTS5), naming, MCP — UI-free, testable
│   ├── Pless/                    ← @main SwiftUI app + CLI (`pless mcp`)
│   └── PlessShare/               ← share extension (Apple share) → PDFs via app group to <vault>/inbox/
└── Tests/PlessTests/             ← MiniTest runner: `swift run --package-path /Users/ptc/dev/ppless PlessTests`
```

## Vault layout

```
~/Documents/Pless/
├── pless.db                     ← SQLite: metadata + FTS5 index
├── documents/YYYY/MM/<name>.pdf ← storage with generated names
├── inbox/                       ← import folder (default; path configurable)
│   └── _abgelehnt/              ← duplicates & unreadable files
└── thumbnails/                  ← cache (regenerable)
```

## Data model (SQLite, `pless.db` in the vault)

```sql
correspondents(id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL);
categories(id INTEGER PRIMARY KEY, name TEXT NOT NULL, parent_id INTEGER REFERENCES categories(id), color TEXT);
-- unique name per level: CREATE UNIQUE INDEX ON categories(name, COALESCE(parent_id, 0))
tags(id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, color TEXT);

documents(
  id INTEGER PRIMARY KEY,
  uuid TEXT UNIQUE NOT NULL,
  sha256 TEXT UNIQUE NOT NULL,            -- dedup
  filename TEXT NOT NULL,                 -- current file name
  relative_path TEXT NOT NULL,            -- documents/YYYY/MM/...
  title TEXT,
  correspondent_id INTEGER REFERENCES correspondents(id),
  category_id INTEGER REFERENCES categories(id),
  document_date TEXT,                     -- ISO, document date
  added_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S','now')),
  page_count INTEGER NOT NULL DEFAULT 0,
  ocr_text TEXT,                          -- extracted text
  ocr_done INTEGER NOT NULL DEFAULT 0,
  needs_review INTEGER NOT NULL DEFAULT 0,
  notes TEXT,
  deleted_at TEXT                         -- trash (soft delete)
);
document_tags(
  document_id INTEGER REFERENCES documents(id),
  tag_id INTEGER REFERENCES tags(id),
  PRIMARY KEY (document_id, tag_id)
);

-- FTS5 (own copy — 'correspondent' is not a column of documents), synced via triggers (migration V2)
documents_fts USING fts5(title, ocr_text, correspondent, tokenize='unicode61');
```

## Ingest pipeline

```
Sources (all lead into the same path):
1. Import folder — defined folder (default `<vault>/inbox`, path configurable in settings), watch via DispatchSource
2. Load PDF directly into the app — drag & drop onto window/list or menu "File > Import…" (NSOpenPanel, multi-select)
3. Apple share (share sheet) — share extension (target `PlessShare`) copies the PDF via app group (shared container; vault path in shared UserDefaults) to `<vault>/inbox/`
   │
   ▼
File → inbox/ (atomic; direct import stages in inbox first)
   │
   ▼
SHA-256 → duplicate? → yes: move to inbox/_abgelehnt/ + report (no vault entry)
   │
   ▼
PDFKit: extract text layer → empty/little? → Vision OCR (background queue, de+en)
   │
   ▼
Heuristics: date (German formats), correspondent (known names), title (first sensible line)
   │
   ▼
Generate file name from template (collision → -2, -3, …)
   │
   ▼
Move to documents/YYYY/MM/ → DB insert (FTS trigger fires) → render thumbnail (cache)
   │
   ▼
Update UI
```

## File names

Template configurable, default: `{date}_{correspondent}_{title}.pdf`
Example: `2026-02-14_Allianz_KFZ-Versicherung-2026.pdf`
Sanitizer: umlauts → `ae/oe/ue/ss`, special characters removed, spaces → `-`,
max ~80 chars. Placeholders: `{date}`, `{correspondent}`, `{category}`, `{title}`, `{tags}`.

## Categories

- Exactly one category per document (optional), freely definable, e.g. "Invoice", "Contract", "Notice"
- Optionally hierarchical via `parent_id`, shown as a tree in the sidebar, e.g.:

```
Categories
├── Invoices
│   ├── Insurance
│   └── Craftsmen
├── Contracts
└── Notices
```

- Color per category (dot in sidebar & chips in the list)
- Filterable in search and MCP; tags stay flat labels (many per document, e.g. "important", "tax2026")

## MCP interface (open standard for AI connection)

- Transport: **stdio**, JSON-RPC 2.0, one JSON message per line, protocolVersion `2025-06-18`
- CLI: `pless mcp --vault <path>`
- Methods: `initialize`, `ping`, `tools/list`, `tools/call`, `notifications/initialized`
- Tools:
  - `search_documents {query, limit?, tag?, correspondent?, category?, from?, to?}` → hits with snippet + score
  - `get_document {document: uuid|sha256}` → metadata + full OCR text + file path + page count
  - `list_documents {tag?, correspondent?, category?, from?, to?, limit?, offset?}` → paginated list
  - `list_categories {}` → all categories incl. `parent_id` (for the tree)
  - `update_document {document, title?, correspondent?, category?, date?, notes?}` → set metadata, incl. category (AI sorts/completes)
  - `assign_tag {document, tag}` → create or assign tag
  - `get_stats {}` → document count, split per year/correspondent/category, tags, inbox state
- Integration e.g. into Claude Desktop:

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

## UI concept (SwiftUI, clean & modern, German)

- `NavigationSplitView` with 3 columns:
  - **Sidebar:** all documents, inbox, categories (tree, colored dots), tags (colored dots), correspondents
  - **List:** thumbnail, title, correspondent, date, tag chips; FTS search via the toolbar search field; sortable
  - **Detail/preview:** PDFView (zoom, page-wise); metadata (title, date, correspondent, category, tags, notes) initially **read-only** — clicking "Edit" (pencil icon in the toolbar) activates edit mode, "Done" saves. On save the file is renamed according to the template if name-relevant fields changed. Also: OCR text can be shown, "Show in Finder"
- **Settings (`Cmd+,`):** vault path, import folder (path, on/off), naming template + live preview, OCR languages, MCP config snippet to copy
- Design: SF Symbols, subtle vibrancy, accent color, dark mode, meaningful empty states

## Test strategy

- MiniTest (`Sources/MiniTest`), runner `Tests/PlessTests`: `swift run --package-path /Users/ptc/dev/ppless PlessTests` — exit code 0 before every commit (CLT has neither XCTest nor Swift Testing macros)
- Fixtures: PDFs are generated at runtime with PDFKit (text PDF + "scanned" PDF image-only)
- OCR behind protocol `TextRecognizer` → Vision implementation in the app, fake in tests
- MCP: feed JSON-RPC line by line, parse responses; manual check with MCP Inspector
- Ingest: end-to-end against a temporary vault in `NSTemporaryDirectory()`

## Development process

- Phases see roadmap below; per phase: implement → `PlessTests` green (exit code 0) →
  small commits (`feat:` + `test:`) → check the box + log line with commit hash
- Directly on `main`, single user, no branches needed
- Definition of done per feature: tests green, feature checked off in this document, log entry present

## Roadmap

### Phase 0 — Setup
- [x] SwiftPM package + framework probe compiles (`swift build`)
- [x] First test green (`swift run PlessTests`, MiniTest)
- [x] git init, `.gitignore`, first commits
- [x] `AGENTS.md` + this document

### Phase 1 — Core: data model + vault + SQLite schema
- [x] Models: Document, Tag, Correspondent, Category (with `parent_id` for hierarchy)
- [x] Vault: create folders, atomic file storage, path management
- [x] SQLite schema + migrations (`pless.db` in the vault, `user_version`)
- [x] Tests

### Phase 2 — Naming engine
- [x] Template renderer `{date}_{correspondent}_{title}` + sanitizer (umlauts, special chars, length limit)
- [x] Collision resolution (`-2`, `-3`, …)
- [x] Tests

### Phase 3 — Ingest
- [x] Import (file → `inbox/` via `stageIntoInbox`), SHA-256 dedup (duplicate → `inbox/_abgelehnt/`)
- [x] PDF text extraction (PDFKit), fallback flag "OCR needed" (`needsReview`, `ocrDone=false`)
- [x] Tests with fixture PDFs (generated at runtime via CoreGraphics/CTLine)

### Phase 4 — OCR
- [x] Vision wrapper behind protocol `TextRecognizer` (fake for tests); renders PDF pages via CoreGraphics (headless), then `VNRecognizeTextRequest`
- [x] Background queue (`OCRService.processPendingAsync`) with progress (done, total)
- [x] Tests (fake recognizer, sync + async)

### Phase 5 — Index & search
- [x] FTS5 index `documents_fts(title, ocr_text, correspondent)` + triggers (migration V2, `user_version=2`)
- [x] Search API: full text (bm25 + snippet « ») + filters (tag / correspondent / category / date) + limit/offset
- [x] Tests (incl. trigger sync after UPDATE)

### Phase 6 — App shell (SwiftUI)
- [x] `@main` app, 3-column layout (sidebar / list / detail)
- [x] Document list with search field
- [x] PDF viewer (PDFView via NSViewRepresentable)
- [x] Thumbnails in the list (cache under `thumbnails/`)

### Phase 7 — Metadata editor
- [x] Preview/detail: metadata read-only; edit mode only after clicking "Edit" (pencil in toolbar); "Done" saves + renames file if needed
- [x] Detail: title, date, correspondent, category, tags, notes
- [x] Management: categories (create, rename, color, nest — sidebar tree + context menu), tags, correspondents
- [x] Rename file per template (incl. first storage from `inbox/` to `documents/YYYY/MM/`, collision `-2`…)

### Phase 8 — Import paths
- [x] Import folder: `<vault>/inbox` (default), watch via DispatchSource (`InboxWatcher`, debounced); new PDFs automatically run through the pipeline and are moved from the folder into the vault
- [x] Load directly into the app: drag & drop onto the window + menu "File > Import…" (NSOpenPanel, multi-select) → same ingest path via `inbox/`
- [ ] Apple share: share extension (target `PlessShare`, activation rule for PDFs) writes via app group (shared container + shared UserDefaults) to `<vault>/inbox/`; pipeline takes over. **Still open:** extension only productive in a signed .app (packaging + signing via Xcode project) — dev test via `inbox/` until then

### Phase 9 — Metadata suggestions (heuristics)
- [x] Detect date (German formats like `14.02.2026`, `01.03.26`, ISO; invalid ones discarded)
- [x] Match correspondent (known names in the OCR text, case-insensitive, longest name wins)
- [x] Title heuristic (first sensible line, without pure date/page numbers)
- [x] Category suggestion (keywords in the OCR text; later via AI through MCP)
- [x] Tests — applies on ingest (text layer) and after OCR, incl. file storage to `documents/YYYY/MM/`

### Phase 10 — MCP server (open standard)
- [x] JSON-RPC 2.0 over stdio: `initialize`, `tools/list`, `tools/call`, `ping`, `notifications/initialized` (protocolVersion `2025-06-18`)
- [x] Tools: `search_documents`, `get_document`, `list_documents`, `list_categories`, `update_document` (incl. file rename), `assign_tag`, `get_stats`
- [x] Tests (JSON-RPC framing, tool calls, error codes) + stdio end-to-end via `pless mcp`
- [x] Docs: config snippet in plan + README + app settings

### Phase 11 — Settings & polish
- [x] Settings (Cmd+,): vault path, import folder (on/off + path), naming template + live preview, OCR languages, MCP config snippet
- [x] Empty states in the list; dark mode via system colors (automatic), SF Symbols

### Phase 12 — Docs & handover
- [x] README: build, run, vault layout, MCP config, known limitations
- [x] Known limitations documented (among others: share extension needs a signed .app)

### Phase 13 — Sync to paperless-ngx (one-way push, opt-in)
> Opt-in exception to the "no network calls" principle: only active once the user
> configures a paperless URL + API token in the settings (self-hosted). Without
> configuration not a single network call is executed.

- [x] Mapping: pless category → paperless **document type**, tag → **tag**, correspondent → **correspondent** (each find-or-create by name → ID); PDF via `POST /api/documents/post_document/` (multipart) with the vault file name (→ paperless `original_filename`); title → `title`, date → `created`
- [x] Idempotency: table `sync_map(document_id, paperless_id, sha256, synced_at)` (migration V3, `user_version=3`) + checksum check `GET /api/documents/?checksum=<sha256>` — already synced/identical documents are skipped, changed sha256 → re-upload
- [x] Metadata re-push: `sync_map.meta_sha256` (migration V5) stores the metadata hash (title/date/correspondent/category/tags/notes) at push; if it differs (e.g. category set afterwards), `PATCH /api/documents/<id>/` goes to paperless — no file re-upload. Metadata edits immediately set `sync_state='not_synced'` locally
- [x] Settings: paperless URL (UserDefaults) + API token (**keychain**, not in pless.db) + "test connection"
- [x] `PaperlessClient` in PlessCore with injectable `HTTPTransport` protocol (app: URLSession, tests: fake): find-or-create for correspondents/tags/document types, `post_document` (multipart), checksum search, `ping`
- [x] `SyncService` in PlessCore: push of all new/changed documents with progress, result (uploaded/skipped/failed), `sync_map` updated
- [x] UI: "Sync" button in the toolbar + "Synchronize" + sync badge (paperless ID) in the details, status/progress in the status bar
- [x] Tests: fake transport (find-or-create, multipart payload, idempotency via checksum, error paths) + sync_map DB tests
- [x] Sync state per document **persisted**: column `documents.sync_state` (`synced` / `not_synced` / `unknown`, migration V4, `user_version=4`, backfill from `sync_map`); transitions: successful push → `synced`, failed push → `not_synced`, once sync is configured → reconcile `unknown` to `not_synced`; without configuration display `unknown`. UI: cloud badge in the top right corner of every PDF card (`cloud.fill` green / `cloud` orange / cloud+"?" grey, with tooltip) + cloud + text in the details
- [x] Forced sync: dropdown on the sync toolbar button + menu in the details — "force categories & metadata" pushes all synced documents via PATCH (`forceMetadata`, even without hash change)
- [x] Pull master data: `listNamed` paginated (`next`) over correspondents/document types/tags; `SyncService.pullMetadata()` imports document types → categories + correspondents → correspondents (case-insensitively idempotent); UI: dropdown on the sync button + button in settings

## Progress log

> Entries quote the original commit messages (German) verbatim — see `git log`.

| Date | Commit | Phase | Feature |
|---|---|---|---|
| 2026-11-15 | 40fbd40 | 0 | Doku committed: AGENTS.md, Plan, README, .gitignore |
| 2026-11-15 | 2f7a88f | 0 | SwiftPM-Skeleton + MiniTest-Runner (CLT: kein XCTest/Testing-Makros) |
| 2026-11-15 | dbff041 | 1 | Core: Models, Vault, SQLite-Schema V1 + CRUD |
| 2026-11-15 | 02807f6 | 1 | Tests: Vault + Database (10 grün) |
| 2026-11-15 | fcfb090 | 2 | Naming Engine: Template-Renderer + Sanitizer + Kollision |
| 2026-11-15 | 21b3a61 | 2 | Naming-Tests (15 gesamt grün) |
| 2026-11-15 | 735570e | 3 | Ingest: SHA-256-Dedup, PDFKit-Text, Duplikat/Reject |
| 2026-11-15 | ec530a9 | 3 | Ingest-Tests mit Fixture-PDFs (20 gesamt grün) |
| 2026-11-15 | 543c0b7 | 4 | OCR: TextRecognizer-Protocol, VisionTextRecognizer, OCRService-Queue |
| 2026-11-15 | 731bc3d | 4 | OCR-Tests (Fake, sync/async) — 24 gesamt grün |
| 2026-11-15 | 62482ec | 5 | FTS5-Index (Migration V2 + Trigger) + Such-API mit Filtern |
| 2026-11-15 | da858a2 | 5 | Search-Tests — 29 gesamt grün |
| 2026-11-15 | b877ab2 | 6 | Core: PDF-Rendering & Thumbnails, tags(for:), onlyNeedsReview-Filter |
| 2026-11-15 | a8163ab | 6 | Thumbnail-Tests + PDFFixture — 32 gesamt grün |
| 2026-11-15 | e56e831 | 6 | App-Shell (SwiftUI): @main, 3 Spalten, Liste+Suche, PDF-Viewer, Thumbnails |
| 2026-11-15 | e994596 | 7 | Core: MetadataService (Speichern + Umbenennen nach Template + Datei-Umzug), Entity-CRUD, moveDocumentFile |
| 2026-11-15 | 3e84c48 | 7 | Metadata-Tests — 41 gesamt grün |
| 2026-11-15 | c56d0cf | 7 | UI: Metadaten-Editor (Bearbeiten/Fertig), Felder+Tags, Verwaltung in Sidebar (Baum, Farben, Kontextmenüs) |
| 2026-11-15 | e85b1cd | 8 | Core: InboxWatcher (DispatchSource auf inbox/, entprellt, ohne _abgelehnt/) |
| 2026-11-15 | b7ee782 | 8 | InboxWatcher-Tests — 45 gesamt grün |
| 2026-11-15 | 518fd3d | 8 | UI: Watcher startet mit App, Drag & Drop PDFs, Menü „Ablage > Importieren…“ |
| 2026-11-15 | bb6c5cc | 9 | Core: Heuristik (Datum/Korrespondent/Titel/Kategorie) greift bei Ingest + nach OCR, Datei-Ablage nach documents/YYYY/MM |
| 2026-11-15 | 045031e | 9 | Heuristik-Tests + Ingest/OCR-End-to-End — 52 gesamt grün |
| 2026-11-15 | 78cfe5b | 9 | UI: OCR-Service mit MetadataService verdrahtet |
| 2026-11-15 | c886cdb | 10 | Core: MCP-Server (JSON-RPC 2.0 stdio, 7 Tools) |
| 2026-11-15 | efa3cfd | 10 | MCP-Tests — 59 gesamt grün |
| 2026-11-15 | 8a12649 | 10 | CLI: `pless mcp --vault <pfad>` startet MCP-Server über stdio |
| 2026-11-15 | 728e708 | 11 | Core: Vault mit eigenem Import-Ordner (inboxOverride) |
| 2026-11-15 | ffe9f27 | 11 | Vault inboxOverride-Test — 60 gesamt grün |
| 2026-11-15 | d8e309d | 11 | UI: Settings (Cmd+,) + Empty States |
| 2026-11-15 | 345c415 | 12 | Docs: README + Phase 10/11/12 abgehakt |
| 2026-11-15 | f330f18 | 12 | build: Scripts/make-app.sh → dist/Pless.app (Release, ad-hoc signiert) |
| 2026-11-15 | 772b94d | 11 | fix: Settings-Sheet per „Fertig“/Esc schließbar |
| 2026-11-15 | c6655dd | 11 | fix: Settings „Schließen“-Button + Auto-Save-Hinweis; make-app.sh baut vor dem Kopieren |
| 2026-11-15 | 1f78620 | 8 | fix: Drag&Drop/Ingest asynchron (kein Main-Thread-Deadlock mehr) — E2E verifiziert |
| 2026-11-15 | 1144b8e | 8 | fix: InboxWatcher + Rename-Events + Poll-Fallback (2 s); Sidebar zeigt Vault-/Posteingang-Pfad — 61 Tests grün |
| 2026-11-15 | 8e0388c | 8 | UI: Posteingang-Badge + „Jetzt scannen“ + Import-Status im Toolbar; Drop auch direkt auf der Liste |
| 2026-11-15 | 1d1ef54 | 8 | UI: Import auto-selektiert, Titelleiste = Vault-Pfad, Detail zeigt Ablagepfad; Watcher-Poll auch ohne kqueue — 61 Tests grün, E2E verifiziert |
| 2026-11-15 | 0d575c3 | 8 | UI: permanente Statusleiste (idle/busy/ok/error) — App sieht nie „kaputt“ aus |
| 2026-11-15 | 8768a84 | 8 | fix: Drag&Drop auf ganzes Fenster + Drop-Hinweis, loadObject(ofClass:) statt deprecated loadItem, PDF-Dokumenttyp + application(open:) für Dock-Drops — 61 Tests grün |
| 2026-11-15 | 7287db7 | 6 | UI: Thumbnail-Gitter statt Zeilen (Tap selektiert, blauer Rahmen), PDF-Zoom (Anpassen/100 %/±) |
| 2026-11-15 | 6f980ec | 6 | UI: Gitter gruppiert nach Jahr/Monat mit Trenner-Überschriften; PDF-Vorschau default „volle skalierte Höhe“ + Modus-Picker (Anpassen/Höhe/100 %) — 61 Tests grün |
| 2026-11-15 | 97c2b93 | 6 | UI: Doubletten-Hinweis beim Import — neuer Status `.warning` (orange) in der Statusleiste; Duplikat (SHA-256) wird nicht erneut importiert, Datei → `_abgelehnt/`, vorhandenes Dokument wird selektiert — 61 Tests grün |
| 2026-11-15 | c8dff98 | 6 | Crash-sichere Imports: stageIntoInbox kopiert nur noch (Original verschwindet nie); RecoveryService beim Start (App + MCP) finalisiert abgebrochene Imports, korrigiert DB-Pfade per SHA-256, adoptiert Waisen-PDFs; Sidebar: Posteingang/Vault im Finder öffnen — 65 Tests grün |
| 2026-11-15 | d43792d | 6 | fix: Thumbnails nicht mehr kopfüber (Flip im CGContext entfernt + Orientierungs-Regressionstest); feat: OCR abbrechen (Statusleiste) + manueller OCR-Start pro Dokument in der Vorschau — 68 Tests grün |
| 2026-11-15 | 95c7ae5 | 6 | App-Icon: `Scripts/make-icon.swift` rendert pless.icns (alle Größen, CoreGraphics), make-app.sh packt es ins Bundle (`CFBundleIconFile=pless`) — 68 Tests grün |
| 2026-11-15 | 7b76c6e | 6 | fix: bestehende (kopfüber) Thumbnails werden beim Start einmalig invalidiert (Format-Marker `.format-v2` in thumbnails/) und on demand neu gerendert — E2E verifiziert, 69 Tests grün |
| 2026-11-15 | 3eee291 | 6 | fix: Import-Race (doppelt gemeldete Posteingang-Datei → duplicateSHA256 als harter Fehler) — process() serialisiert, Race → .duplicate, in-flight-Schutz in AppState, lesbare PlessError-Texte — 70 Tests grün |
| 2026-11-15 | a2d76fa | 6 | feat: Bulk-Operationen — Mehrfachauswahl im Gitter (Klick / Cmd+Klick / Shift-Bereich / Cmd+A) + Leiste mit Kategorie-Picker und Tag-Feld für alle ausgewählten Dokumente — 71 Tests grün |
| 2026-11-15 | aa92444 | 6 | feat: Kategorie/Tag per Drag & Drop aus der Sidebar aufs Gitter ziehen (Mehrfachauswahl wird als Zielmenge genommen, wenn die Karte selektiert ist) — 71 Tests grün |
| 2026-11-15 | 0cdf5c7 | 6 | fix: Kategorie-Aufklapp-Pfeil (>) nur noch bei echten Unterkategorien sichtbar — 71 Tests grün |
| 2026-11-15 | ae7514c | 6 | feat: Sidebar-Drag über der Liste highlightet alle selektierten Karten (gestrichelt); Drop weist Kategorie/Tag der ganzen Mehrfachauswahl zu — 71 Tests grün |
| 2026-11-15 | 3bd1d60 | 6 | feat: Zähler-Badge hinter jeder Kategorie in der Sidebar (inkl. Unterkategorien, 0 ausgeblendet) — 72 Tests grün |
| 2026-11-15 | b616e6a | 6 | feat: mehrere Datums-Vorschläge als Chips im Metadaten-Editor (extractDates); OCR-Text-Panel in der Vorschau (markierbar) — 73 Tests grün |
| 2026-11-15 | fa27ebd | 6 | feat: Bearbeiten/Fertig/Abbrechen in der Detail-Vorschau; Edit-Modus sperrt Selektionswechsel (Details bleiben stabil) — 73 Tests grün |
| 2026-11-15 | b4b192f | 6 | feat: Datumsanzeige im eingestellten Format (Default dd.MM.yyyy) in Liste/Detail/Edit-Modus; Eingabe wird auf ISO normalisiert; Setting „Datumsformat“ — 76 Tests grün |
| 2026-11-15 | f5f5ddc | 6 | feat: Bearbeiten unten in den Details; Datums-Vorschläge als Chips auch in der Detail-Summary — 76 Tests grün |
| 2026-11-16 | 646f6f6 | 6 | feat: Heuristik erkennt Langdaten wie „8. Oktober 2026“ (inkl. Abkürzungen) → Kurzform yyyy-MM-dd in den Datums-Vorschlägen — 77 Tests grün |
| 2026-11-16 | 59baef5 | 6 | feat: Heuristik erkennt US-Datum 12/08/2026 (MM/DD/YYYY) → 2026-12-08, auch 2-stelliges Jahr — 78 Tests grün |
| 2026-11-16 | e6391aa | 6 | feat: Kategorie-Klick filtert Übersicht; farbiges Kategorie-Tag auf den Karten; Auto-Farbe pro Kategorie (Palette) — 79 Tests grün |
| 2026-11-16 | 76fb003 | 6 | feat: Kategorie-Auswahl wird in der Sidebar markiert; erneuter Klick → wieder alle Dokumente — 79 Tests grün |
| 2026-11-16 | c84256d | 6 | feat: aktive Karte im Gitter stärker markiert (Rahmen + Füllung + Häkchen), ausgewählte nur Rahmen — 79 Tests grün |
| 2026-11-16 | cb5e0d7 | 6 | feat: Klick auf Dokument wählt dessen Kategorie in der Sidebar aus (markiert + filtert) — 79 Tests grün |
| 2026-11-16 | d862d9d | 6 | revert: Klick auf PDF markiert nur das PDF; Kategorie-Klick markiert/filtert die Kategorie — 79 Tests grün |
| 2026-11-16 | 7f5504c | 6 | fix: Kategorie-Markierung auch mit Zähler-Badge (explizites Highlight über sidebarSelection) — 79 Tests grün |
| 2026-11-16 | 52f4953 | 6 | fix: Kategorie-/Tag-Filter wählt nicht mehr automatisch das erste PDF aus — 79 Tests grün |
| 2026-11-16 | c2ac798 | 6 | fix: Kategorie-Zähler als trailing Text statt .badge() — native Auswahl-Markierung wieder überall — 79 Tests grün |
| 2026-11-16 | 41f4f73 | 6 | fix: OCR-Text-Panel default zu; Notizfeld im Edit-Modus leer klein — 79 Tests grün |
| 2026-11-16 | 656f4e6 | 6 | feat: Korrespondenten — Vorschlag in Details mit Übernehmen-Chip, Zähler + Filter-Toggle in Sidebar, Neuanlegen — 81 Tests grün |
| 2026-11-16 | e8e2be8 | 6 | feat: Korrespondent per Drag & Drop aufs Gitter zuweisen; Doppelklick in Sidebar = umbenennen — 82 Tests grün |
| 2026-11-16 | 2cb0013 | 6 | fix: Korrespondent-Vorschlag ab Rechtsform abschneiden (Böttcher AG … → Böttcher AG); Behörden ganz — 82 Tests grün |
| 2026-11-16 | 6900edf | 13 | feat(core): Sync-Status persistiert — Migration V4 (sync_state: synced/not_synced/unknown, Backfill aus sync_map) — 91 Tests grün |
| 2026-11-16 | d7359d0 | 13 | feat(ui): Wolken-Badge pro PDF (cloud.fill/cloud/cloud.questionmark) + Sync-Stand in den Details — 91 Tests grün |
| 2026-11-16 | 212dba8 | 13 | fix(core): Metadaten-Re-Push per PATCH bei meta_sha256-Abweichung (Migration V5) — 92 Tests grün |
| 2026-11-16 | 96b3a5e | 13 | feat(ui): Sync-Status zählt „aktualisiert“ (PATCH) — 92 Tests grün |
| 2026-11-16 | 329db30 | 12/13 | docs: README um Sync nach paperless-ngx ergänzt (Push, Mapping, Idempotenz, Wolken-Badge) — 92 Tests grün |
| 2026-11-16 | e60b396 | 13 | fix(core): PATCH sendet title/created nur bei Wert (paperless 400 bei null) — Resync nach Metadaten-Edit wieder ok — 92 Tests grün |
| 2026-11-16 | 758bb68 | 13 | fix(ui): Wolken-Badge größer/deutlicher (13pt, volle Scheibe) — 92 Tests grün |
| 2026-11-16 | 163e1b2 | 13 | fix(ui): unknown-Wolke als cloud+„?“ komponiert (cloud.questionmark fehlt im SF-Katalog → leer gerendert); Sync/Resync über echtes HTTP gegen Fake-paperless verifiziert (Upload mit document_type, PATCH nach Kategorie-Edit) — 92 Tests grün |
| 2026-11-16 | de60b92 | 13 | fix(core): find-or-create-Fallback results.first lieferte bei ignoriertem name-Filter immer denselben Document Type („Arbeitsvertrag“) — jetzt nur exakter case-insensitiver Treffer — 92 Tests grün |
| 2026-11-16 | 10c335f | 13 | feat(core): forceMetadata-Sync (PATCH auch bei unverändertem meta-Hash) — 92 Tests grün |
| 2026-11-16 | a4002d6 | 13 | feat(ui): Dropdown am Sync-Toolbar-Button + Detail-Menü mit „Metadaten erzwingen“ — 92 Tests grün |
| 2026-11-16 | f0d3fcd | 13 | feat(core): Pull-Import paperless→pless (Document Types→Kategorien, Correspondents→Korrespondenten, paginiert, idempotent) — 94 Tests grün |
| 2026-11-16 | e2eb12d | 13 | feat(ui): Import-Eintrag im Sync-Dropdown (Toolbar) — 94 Tests grün |
| 2026-11-16 | ca06035 | — | docs: README als Programmbeschreibung, technischer Hintergrund nach docs/technik.md — 94 Tests grün |
| 2026-11-16 | 78829c4 | — | docs: README mit eigenem paperless-ngx-Abschnitt — 94 Tests grün |
| 2026-11-16 | bec38c0 | UI | fix(ui): Posteingang als eigene Leiste oben in der Sidebar (Status-Pill + Scannen-Button), schaltet nicht mehr auf „Alle Dokumente“ um — 94 Tests grün |
| 2026-11-16 | dd73b26 | UI | fix(ui): Sync-Toolbar als ein Split-Button (Klick = Sync, Chevron = Menü) statt zweier getrennter Buttons — 94 Tests grün |
| 2026-11-16 | b84b05d | UI | fix(ui): Sync-Button flach ohne Kasten, Symbol arrow.2.circlepath; Chevron-Menü borderless daneben — 94 Tests grün |
| 2026-11-16 | f7d1b05 | UI | fix(ui): Sync-Toolbar ein einzelner Button mit einem Symbol (arrow.clockwise); Varianten per Rechtsklick — 94 Tests grün |
| 2026-11-16 | 420ba73 | UI | fix(ui): Sync als einzelner Dropdown-Button (cloud.arrow.up, ein Pfeil); Menü: Sync/Erzwingen/Import — 94 Tests grün |
| 2026-11-16 | d4255ca | UI | fix(ui): Sync-Symbol komponiert aus cloud.fill + arrow.up (beides sichtbar); Menü-Punkte kürzer benannt — 94 Tests grün |
| 2026-11-16 | 730480d | 13/UI | feat: paperless-Einstellungen als Tab-Fenster, Token in Keychain; fix: EnvironmentObject-Crash im Settings-Sheet — 94 Tests grün |
| 2026-11-16 | 21c4ef6 | UI | fix(ui): Spalten-Mindestbreiten im Split-View (Sidebar min. 230pt, Vorschau initial 400pt), Fenster min. 1000pt — 94 Tests grün |
| 2026-11-16 | 1984e36 | UI | fix(ui): Datums-Vorschläge in den Details wrappen per FlowLayout statt in einer Zeile zu schrumpfen — 94 Tests grün |
| 2026-11-17 | 7d43e7e | — | chore: LICENSE GPL-3.0-or-later + README-Lizenzabschnitt (Dual Licensing, Forks ok, keine externen Abhängigkeiten) — 94 Tests grün |
| 2026-11-17 | dcc5726 | 9 | feat: OCR konfigurierbar (Genauigkeit fast/accurate, dpi 200/300/400, Sprachkorrektur) — Default 300 dpi — 95 Tests grün |
| 2026-11-17 | c5c6895 | 9/UI | feat(ui): OCR pro Dokument erneut anstoßen („OCR erneut“ in der Detail-Vorschau, auch wenn schon done) — 95 Tests grün |
| 2026-11-17 | 3750379 | 9/UI | fix(ui): OCR in der Detail-Leiste als Icon-Dropdown (doc.text.viewfinder) statt Text-Buttons — 95 Tests grün |
| 2026-11-17 | a82dbd5 | — | fix: alle Build-Warnings beseitigt (Sendable via FULLMUTEX, deprecated APIs, try?-Results, NSLock in @MainActor) — 0 Warnings Debug+Release, 95 Tests grün |
| 2026-11-17 | 2a51dd7 | 9/UI | feat(ui): OCR-Text in der Vorschau markieren → Rechtsklick „Als Titel/Korrespondent übernehmen“ — 96 Tests grün |
| 2026-11-17 | 592ff88 | 9/UI | feat(ui): Text direkt im PDFView selektieren → Rechtsklick „Als Titel/Korrespondent übernehmen“ — 96 Tests grün |
| 2026-11-17 | 238c771 | — | feat: App-Icon aus docs/pless-icon.jpg (neues Script make-icon-from-image.swift, Bundle verifiziert) + Icon in README — 96 Tests grün |
| 2026-11-17 | e7d961a | — | feat: App-Icon aus docs/pless-app-icon-svg.svg (qlmanage→PNG→iconset), Orientation-Fix kopfüber, README zeigt SVG — 96 Tests grün |
| 2026-11-17 | 7dc2e75 | — | docs: englische Versionen aller Docs (.en.md) + Sprachumschalter in der README — 96 Tests grün |
| 2026-11-17 | 80cd00d | — | feat: App-UI zweisprachig (de/en) — L10n-Tabelle in PlessCore, Sprachwahl in den Einstellungen → Allgemein — 98 Tests grün |
| 2026-11-17 | 28ead0c | — | feat: UI-Sprache „System“ als Default (system/de/en) — OS-Sprache entscheidet ansonsten — 99 Tests grün |
| 2026-11-17 | 524a02a | — | feat: Datumsformat „System“ als Default — Anzeige folgt OS-Locale, DB bleibt ISO — 100 Tests grün |
| 2026-11-17 | 50e9099 | — | docs: Disclaimer in README (de/en) — Benutzung auf eigene Gefahr, keine Verbindung zu paperless-ngx, Marken der jeweiligen Organisationen — 100 Tests grün |
| 2026-11-17 | 6d86396 | — | docs: Dual-Licensing-Hinweis entschärft (noch Alpha, kein aktives Angebot) — 100 Tests grün |
| 2026-11-17 | e1f2fb2 | — | docs: Dual-Licensing-Absatz ganz entfernt aus den READMEs — 100 Tests grün |

## Open points / later ideas
- Implement MCP protocolVersion `2025-06-18`
- OCR `accurate` vs. `fast` configurable
- Category suggestion by the connected AI (MCP roundtrip)
- Xcode 27.2 is installed (`xcode-select` → `/Applications/Xcode.app`) — full toolchain active. `.app` packaging is there: `Scripts/make-app.sh` → `dist/Pless.app` (ad-hoc signed). Still open: Developer-ID signing + share extension/app group (needs an Xcode project, phase 8) and optional XCTest/Swift Testing instead of MiniTest. Quick Look, menu-bar extra, export: later
