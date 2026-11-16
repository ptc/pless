# pless — Implementierungsplan & Fortschritt

Native macOS-App für lokales Dokumentenmanagement (Paperless, aber lokal & nativ):
PDFs sortieren, per OCR indizieren, anzeigen, mit vernünftigen Dateinamen an einem
Ort ablegen, durchsuchen und über den offenen Standard **MCP** an eine KI anbinden.
Kein Cloud, Single User.

## Festgelegte Architektur-Entscheidungen

| Thema | Entscheidung | Begründung |
|---|---|---|
| Stack | Swift 6.4 + SwiftPM; Xcode 27.2 installiert & aktiv (volle Toolchain, kein sudo) | `swift build` / `swift run` reichen; XCTest/Swift Testing optional später |
| Dependencies | keine externen Pakete | CLT/offline-sicher; SQLite via `import SQLite3`, MCP selbst implementiert |
| UI | SwiftUI + AppKit-Hybrid, reiner Code (keine Storyboards), SF Symbols, UI auf Deutsch | modern, schlicht, Dark Mode inklusive |
| Ablage | ein Vault-Ordner (Default `~/Documents/Pless`), `pless.db` liegt im Vault | „ein Ort", portabel, alles lokal |
| Dateinamen | Template `{date}_{correspondent}_{title}.pdf`, sanitized, Kollisionszähler | menschenlesbar & sortierbar |
| OCR | Apple Vision (`VNRecognizeTextRequest`), de+en, on-device | kein Cloud, System-Framework |
| Suche | SQLite FTS5 über Titel + OCR-Text + Metadaten | lokal, schnell, ohne Dependency |
| KI-Anbindung | MCP (Model Context Protocol) als CLI-Subkommando `pless mcp` über stdio | offener Standard, lokal (z. B. Claude Desktop) |
| Ablage-Kopie | eine kanonische Kopie mit generiertem Namen (kein original+archiv-Duplikat) | „an einem Ort", aufgeräumt |
| Klassifikation | **Kategorien** (optional hierarchisch, genau eine pro Dokument) + flache Tags (viele pro Dokument) + Korrespondenten | Kategorien zum Ordnen, Tags zum Markieren |
| Import | Import-Ordner (Watch) + Drag & Drop/Dateidialog + Apple-Teilen (Share Extension → App Group → inbox/) | alle Wege münden in eine Pipeline |
| Tests | MiniTest (eigener Runner in `Sources/MiniTest`, Tests in `Tests/PlessTests`), vor jedem Commit Exit-Code 0 | CLT liefert weder XCTest noch Swift-Testing-Makros; Tests gehören zum Feature |
| Commits | klein & häufig, Conventional Commits | iterativ, nachvollziehbar |

## Projekt-Layout

```
pless/
├── Package.swift
├── AGENTS.md                     ← Vorgehen (verbindlich)
├── docs/implementierung.md       ← dieses Dokument: Plan + Fortschritt
├── Sources/
│   ├── MiniTest/                 ← minimales Test-Framework (CLT: kein XCTest, keine Testing-Makros)
│   ├── PlessCore/                ← Model, Vault, Ingest, OCR, Index (FTS5), Naming, MCP — UI-frei, testbar
│   ├── Pless/                    ← @main SwiftUI-App + CLI (`pless mcp`)
│   └── PlessShare/               ← Share Extension (Apple-Teilen) → PDFs via App Group nach <vault>/inbox/
└── Tests/PlessTests/             ← MiniTest-Runner: `swift run --package-path /Users/ptc/dev/ppless PlessTests`
```

## Vault-Layout

```
~/Documents/Pless/
├── pless.db                     ← SQLite: Metadaten + FTS5-Index
├── documents/YYYY/MM/<name>.pdf ← Ablage mit generierten Namen
├── inbox/                       ← Import-Ordner (Default; Pfad konfigurierbar)
│   └── _abgelehnt/              ← Duplikate & unleserliche Dateien
└── thumbnails/                  ← Cache (regenerierbar)
```

## Datenmodell (SQLite, `pless.db` im Vault)

```sql
correspondents(id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL);
categories(id INTEGER PRIMARY KEY, name TEXT NOT NULL, parent_id INTEGER REFERENCES categories(id), color TEXT);
-- eindeutiger Name pro Ebene: CREATE UNIQUE INDEX ON categories(name, COALESCE(parent_id, 0))
tags(id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, color TEXT);

documents(
  id INTEGER PRIMARY KEY,
  uuid TEXT UNIQUE NOT NULL,
  sha256 TEXT UNIQUE NOT NULL,            -- Dedup
  filename TEXT NOT NULL,                 -- aktueller Dateiname
  relative_path TEXT NOT NULL,            -- documents/YYYY/MM/...
  title TEXT,
  correspondent_id INTEGER REFERENCES correspondents(id),
  category_id INTEGER REFERENCES categories(id),
  document_date TEXT,                     -- ISO, Datum des Dokuments
  added_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S','now')),
  page_count INTEGER NOT NULL DEFAULT 0,
  ocr_text TEXT,                          -- extrahierter Text
  ocr_done INTEGER NOT NULL DEFAULT 0,
  needs_review INTEGER NOT NULL DEFAULT 0,
  notes TEXT,
  deleted_at TEXT                         -- Papierkorb (Soft Delete)
);
document_tags(
  document_id INTEGER REFERENCES documents(id),
  tag_id INTEGER REFERENCES tags(id),
  PRIMARY KEY (document_id, tag_id)
);

-- FTS5 (eigene Kopie — 'correspondent' ist keine Spalte von documents), Sync über Trigger (Migration V2)
documents_fts USING fts5(title, ocr_text, correspondent, tokenize='unicode61');
```

## Ingest-Pipeline

```
Quellen (alle münden in denselben Weg):
1. Import-Ordner — definierter Ordner (Default `<vault>/inbox`, Pfad in Settings konfigurierbar), Watch via DispatchSource
2. PDF direkt in die App laden — Drag & Drop auf Fenster/Liste oder Menü „Ablage > Importieren…“ (NSOpenPanel, Mehrfachauswahl)
3. Apple-Teilen (Share Sheet) — Share Extension (Target `PlessShare`) kopiert die PDF über App Group (shared container; Vault-Pfad in gemeinsamen UserDefaults) nach `<vault>/inbox/`
   │
   ▼
Datei → inbox/ (atomar; Direkt-Import lagert erst in inbox zwischen)
   │
   ▼
SHA-256 → Duplikat? → ja: nach inbox/_abgelehnt/ verschieben + melden (kein Vault-Eintrag)
   │
   ▼
PDFKit: Textschicht extrahieren → leer/wenig? → Vision OCR (Hintergrund-Queue, de+en)
   │
   ▼
Heuristik: Datum (deutsche Formate), Korrespondent (bekannte Namen), Titel (erste sinnvolle Zeile)
   │
   ▼
Dateiname aus Template generieren (Kollision → -2, -3, …)
   │
   ▼
verschieben nach documents/YYYY/MM/ → DB-Insert (FTS-Trigger feuert) → Thumbnail rendern (Cache)
   │
   ▼
UI aktualisieren
```

## Dateinamen

Template konfigurierbar, Default: `{date}_{correspondent}_{title}.pdf`
Beispiel: `2026-02-14_Allianz_KFZ-Versicherung-2026.pdf`
Sanitizer: Umlaute → `ae/oe/ue/ss`, Sonderzeichen entfernt, Leerzeichen → `-`,
max. ~80 Zeichen. Platzhalter: `{date}`, `{correspondent}`, `{category}`, `{title}`, `{tags}`.

## Kategorien

- Genau eine Kategorie pro Dokument (optional), frei definierbar, z. B. „Rechnung", „Vertrag", „Bescheid"
- Optional hierarchisch über `parent_id`, in der Sidebar als Baum, z. B.:

```
Kategorien
├── Rechnungen
│   ├── Versicherungen
│   └── Handwerker
├── Verträge
└── Bescheide
```

- Farbe pro Kategorie (Punkt in Sidebar & Chips in der Liste)
- Filterbar in Suche und MCP; Tags bleiben flache Labels (viele pro Dokument, z. B. „wichtig", „steuer2026")

## MCP-Schnittstelle (offener Standard für die KI-Anbindung)

- Transport: **stdio**, JSON-RPC 2.0, eine JSON-Nachricht pro Zeile, protocolVersion `2025-06-18`
- CLI: `pless mcp --vault <pfad>`
- Methoden: `initialize`, `ping`, `tools/list`, `tools/call`, `notifications/initialized`
- Tools:
  - `search_documents {query, limit?, tag?, correspondent?, category?, from?, to?}` → Treffer mit Snippet + Score
  - `get_document {document: uuid|sha256}` → Metadaten + kompletter OCR-Text + Dateipfad + Seitenzahl
  - `list_documents {tag?, correspondent?, category?, from?, to?, limit?, offset?}` → paginierte Liste
  - `list_categories {}` → alle Kategorien inkl. `parent_id` (für den Baum)
  - `update_document {document, title?, correspondent?, category?, date?, notes?}` → Metadaten setzen, inkl. Kategorie (KI sortiert/ergänzt)
  - `assign_tag {document, tag}` → Tag anlegen bzw. zuweisen
  - `get_stats {}` → Anzahl Dokumente, Aufteilung pro Jahr/Korrespondent/Kategorie, Tags, Inbox-Stand
- Einbindung z. B. in Claude Desktop:

```json
{
  "mcpServers": {
    "pless": {
      "command": "<pfad-zum-binary>/Pless",
      "args": ["mcp", "--vault", "/Users/ptc/Documents/Pless"]
    }
  }
}
```

## UI-Konzept (SwiftUI, schlicht & modern, Deutsch)

- `NavigationSplitView` mit 3 Spalten:
  - **Sidebar:** Alle Dokumente, Posteingang (Inbox), Kategorien (Baum, farbige Punkte), Tags (farbige Punkte), Korrespondenten
  - **Liste:** Thumbnail, Titel, Korrespondent, Datum, Tag-Chips; FTS-Suche über das Suchfeld in der Toolbar; sortierbar
  - **Detail/Vorschau:** PDFView (Zoom, seitenweise); Metadaten (Titel, Datum, Korrespondent, Kategorie, Tags, Notizen) zunächst **read-only** — erst Klick auf „Bearbeiten“ (Stift-Symbol in der Toolbar) aktiviert den Edit-Modus, „Fertig“ speichert. Beim Speichern wird die Datei nach Template umbenannt, wenn sich namensrelevante Felder geändert haben. Außerdem: OCR-Text einblendbar, „Im Finder zeigen"
- **Settings (`Cmd+,`):** Vault-Pfad, Import-Ordner (Pfad, an/aus), Namensschema + Live-Vorschau, OCR-Sprachen, MCP-Config-Snippet zum Kopieren
- Design: SF Symbols, dezente Vibrancy, Accent-Color, Dark Mode, aussagekräftige Empty States

## Teststrategie

- MiniTest (`Sources/MiniTest`), Runner `Tests/PlessTests`: `swift run --package-path /Users/ptc/dev/ppless PlessTests` — Exit-Code 0 vor jedem Commit (CLT hat weder XCTest noch Swift-Testing-Makros)
- Fixtures: PDFs werden zur Laufzeit mit PDFKit erzeugt (Text-PDF + „gescannt"-PDF nur Bild)
- OCR hinter Protocol `TextRecognizer` → Vision-Implementierung in der App, Fake in den Tests
- MCP: JSON-RPC zeilenweise füttern, Antworten parsen; manueller Check mit MCP Inspector
- Ingest: End-to-End gegen temporäres Vault in `NSTemporaryDirectory()`

## Entwicklungsprozess

- Phasen siehe Roadmap unten; pro Phase: implementieren → `PlessTests` grün (Exit-Code 0) →
  kleine Commits (`feat:` + `test:`) → Checkbox abhaken + Log-Zeile mit Commit-Hash
- Direkt auf `main`, Single User, keine Branches nötig
- Definition of Done pro Feature: Tests grün, Feature in diesem Dokument abgehakt, Log-Eintrag vorhanden

## Roadmap

### Phase 0 — Setup
- [x] SwiftPM-Package + Framework-Probe kompiliert (`swift build`)
- [x] Erster Test grün (`swift run PlessTests`, MiniTest)
- [x] git init, `.gitignore`, erste Commits
- [x] `AGENTS.md` + dieses Dokument

### Phase 1 — Core: Datenmodell + Vault + SQLite-Schema
- [x] Models: Document, Tag, Correspondent, Category (mit `parent_id` für Hierarchie)
- [x] Vault: Ordner anlegen, atomare Dateiablage, Pfadverwaltung
- [x] SQLite-Schema + Migrationen (`pless.db` im Vault, `user_version`)
- [x] Tests

### Phase 2 — Naming Engine
- [x] Template-Renderer `{date}_{correspondent}_{title}` + Sanitizer (Umlaute, Sonderzeichen, Längenlimit)
- [x] Kollisionsauflösung (`-2`, `-3`, …)
- [x] Tests

### Phase 3 — Ingest
- [x] Import (Datei → `inbox/` via `stageIntoInbox`), SHA-256-Dedup (Duplikat → `inbox/_abgelehnt/`)
- [x] PDF-Textextraktion (PDFKit), Fallback-Flag „OCR nötig" (`needsReview`, `ocrDone=false`)
- [x] Tests mit Fixture-PDFs (werden per CoreGraphics/CTLine zur Laufzeit erzeugt)

### Phase 4 — OCR
- [x] Vision-Wrapper hinter Protocol `TextRecognizer` (Fake für Tests); rendert PDF-Seiten per CoreGraphics (headless), dann `VNRecognizeTextRequest`
- [x] Hintergrund-Queue (`OCRService.processPendingAsync`) mit Fortschritt (done, total)
- [x] Tests (Fake-Recognizer, sync + async)

### Phase 5 — Index & Suche
- [x] FTS5-Index `documents_fts(title, ocr_text, correspondent)` + Trigger (Migration V2, `user_version=2`)
- [x] Such-API: Volltext (bm25 + Snippet « ») + Filter (Tag / Korrespondent / Kategorie / Datum) + Limit/Offset
- [x] Tests (inkl. Trigger-Sync nach UPDATE)

### Phase 6 — App-Shell (SwiftUI)
- [x] `@main` App, 3-Spalten-Layout (Sidebar / Liste / Detail)
- [x] Dokumentliste mit Suchfeld
- [x] PDF-Viewer (PDFView via NSViewRepresentable)
- [x] Thumbnails in der Liste (Cache unter `thumbnails/`)

### Phase 7 — Metadaten-Editor
- [x] Vorschau/Detail: Metadaten read-only; Edit-Modus erst per Klick auf „Bearbeiten“ (Stift in Toolbar); „Fertig“ speichert + benennt Datei ggf. um
- [x] Detail: Titel, Datum, Korrespondent, Kategorie, Tags, Notizen
- [x] Verwaltung: Kategorien (anlegen, umbenennen, Farbe, verschachteln — Sidebar-Baum + Kontextmenü), Tags, Korrespondenten
- [x] Umbenennen der Datei nach Template (inkl. Erst-Ablage aus `inbox/` nach `documents/YYYY/MM/`, Kollision `-2`…)

### Phase 8 — Import-Wege
- [x] Import-Ordner: `<vault>/inbox` (Default), Watch via DispatchSource (`InboxWatcher`, entprellt); neue PDFs laufen automatisch in die Pipeline und werden aus dem Ordner in den Vault verschoben
- [x] Direkt in die App laden: Drag & Drop auf das Fenster + Menü „Ablage > Importieren…“ (NSOpenPanel, Mehrfachauswahl) → gleicher Ingest-Weg über `inbox/`
- [ ] Apple-Teilen: Share Extension (Target `PlessShare`, ActivationRule für PDFs) schreibt via App Group (shared container + gemeinsame UserDefaults) nach `<vault>/inbox/`; Pipeline übernimmt. **Noch offen:** Extension erst in signiertem .app produktiv (.app-Packaging + Signing via Xcode-Projekt) — Dev-Test bis dahin über `inbox/`

### Phase 9 — Metadaten-Vorschläge (Heuristik)
- [x] Datum erkennen (deutsche Formate wie `14.02.2026`, `01.03.26`, ISO; ungültige werden verworfen)
- [x] Korrespondent matchen (bekannte Namen im OCR-Text, case-insensitive, längster Name gewinnt)
- [x] Titel-Heuristik (erste sinnvolle Zeile, ohne reine Datums-/Seitennummern)
- [x] Kategorie-Vorschlag (Schlüsselwörter im OCR-Text; später per KI via MCP)
- [x] Tests — greift beim Ingest (Textschicht) und nach OCR, inkl. Datei-Ablage nach `documents/YYYY/MM/`

### Phase 10 — MCP-Server (offener Standard)
- [x] JSON-RPC 2.0 über stdio: `initialize`, `tools/list`, `tools/call`, `ping`, `notifications/initialized` (protocolVersion `2025-06-18`)
- [x] Tools: `search_documents`, `get_document`, `list_documents`, `list_categories`, `update_document` (inkl. Datei-Umbenennen), `assign_tag`, `get_stats`
- [x] Tests (JSON-RPC-Framing, Tool-Aufrufe, Fehlercodes) + stdio-End-to-End via `pless mcp`
- [x] Doku: Config-Snippet in Plan + README + App-Settings

### Phase 11 — Settings & Polish
- [x] Settings (Cmd+,): Vault-Pfad, Import-Ordner (an/aus + Pfad), Namensschema + Live-Vorschau, OCR-Sprachen, MCP-Config-Snippet
- [x] Empty States in der Liste; Dark Mode über Systemfarben (automatisch), SF Symbols

### Phase 12 — Doku & Übergabe
- [x] README: Build, Run, Vault-Layout, MCP-Config, bekannte Einschränkungen
- [x] Bekannte Einschränkungen dokumentiert (u. a. Share Extension braucht signiertes .app)

### Phase 13 — Sync nach paperless-ngx (Einweg-Push, opt-in)
> Opt-in-Ausnahme vom Grundsatz „keine Netzwerk-Calls“: erst aktiv, wenn der User in den
> Settings eine paperless-URL + API-Token konfiguriert (self-hosted). Ohne Konfiguration
> wird kein einziger Netzwerk-Call ausgeführt.

- [x] Mapping: pless-Kategorie → paperless **Document Type**, Tag → **Tag**, Korrespondent → **Correspondent** (jeweils find-or-create per Name → ID); PDF via `POST /api/documents/post_document/` (multipart) mit Vault-Dateinamen (→ paperless `original_filename`); Titel → `title`, Datum → `created`
- [x] Idempotenz: Tabelle `sync_map(document_id, paperless_id, sha256, synced_at)` (Migration V3, `user_version=3`) + Checksum-Check `GET /api/documents/?checksum=<sha256>` — bereits gesyncte/identische Dokumente werden übersprungen, bei geändertem sha256 neu hochgeladen
- [x] Metadaten-Re-Push: `sync_map.meta_sha256` (Migration V5) speichert den Metadaten-Hash (Titel/Datum/Korrespondent/Kategorie/Tags/Notizen) beim Push; weicht er ab (z. B. Kategorie nachträglich gesetzt), geht `PATCH /api/documents/<id>/` an paperless — kein Re-Upload der Datei. Metadaten-Edits setzen lokal sofort `sync_state='not_synced'`
- [x] Settings: paperless-URL (UserDefaults) + API-Token (**Keychain**, nicht in pless.db) + „Verbindung testen“
- [x] `PaperlessClient` in PlessCore mit injizierbarem `HTTPTransport`-Protocol (App: URLSession, Tests: Fake): find-or-create für Correspondents/Tags/Document Types, `post_document` (multipart), Checksum-Suche, `ping`
- [x] `SyncService` in PlessCore: Push aller neuen/geänderten Dokumente mit Fortschritt, Ergebnis (uploaded/skipped/failed), `sync_map` aktualisieren
- [x] UI: „Sync“-Button in der Toolbar + „Synchronisieren“ + Sync-Badge (paperless-ID) in den Details, Status/Progress in der Statusleiste
- [x] Tests: Fake-Transport (find-or-create, multipart-Payload, Idempotenz via Checksum, Fehlpfade) + sync_map-DB-Tests
- [x] Sync-Stand pro Dokument **persistiert**: Spalte `documents.sync_state` (`synced` / `not_synced` / `unknown`, Migration V4, `user_version=4`, Backfill aus `sync_map`); Transitionen: erfolgreicher Push → `synced`, fehlgeschlagener Push → `not_synced`, sobald Sync konfiguriert → `unknown` per Reconcile auf `not_synced`; ohne Konfiguration Anzeige `unknown`. UI: Wolken-Badge in der oberen rechten Ecke jeder PDF-Karte (`cloud.fill` grün / `cloud` orange / Wolke+„?“ grau, mit Tooltip) + Wolke + Text in den Details
- [x] Forced Sync: Dropdown am Sync-Toolbar-Button + Menü in den Details — „Kategorien & Metadaten erzwingen“ pusht per `forceMetadata` alle gesyncten Dokumente per PATCH (auch ohne Hash-Änderung)
- [x] Pull-Stammdaten: `listNamed` paginiert (`next`) über Correspondents/Document Types/Tags; `SyncService.pullMetadata()` importiert Document Types → Kategorien + Correspondents → Korrespondenten (case-insensitiv idempotent); UI: Dropdown am Sync-Button + Button in den Settings

## Fortschritts-Log

| Datum | Commit | Phase | Feature |
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

## Offene Punkte / spätere Ideen
- MCP protocolVersion `2025-06-18` umsetzen
- OCR `accurate` vs. `fast` konfigurierbar
- Kategorie-Vorschlag durch die angebundene KI (MCP-Roundtrip)
- Xcode 27.2 ist installiert (`xcode-select` → `/Applications/Xcode.app`) — volle Toolchain aktiv. `.app`-Packaging ist da: `Scripts/make-app.sh` → `dist/Pless.app` (ad-hoc signiert). Noch offen: Developer-ID-Signing + Share Extension/App Group (braucht Xcode-Projekt, Phase 8) und optional XCTest/Swift Testing statt MiniTest. Quick Look, Menu-Bar-Extra, Export: später
