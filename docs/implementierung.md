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

## Fortschritts-Log

| Datum | Commit | Phase | Feature |
|---|---|---|---|
| 2026-11-15 | ce00c6b | 0 | Doku committed: AGENTS.md, Plan, README, .gitignore |
| 2026-11-15 | 6c37c03 | 0 | SwiftPM-Skeleton + MiniTest-Runner (CLT: kein XCTest/Testing-Makros) |
| 2026-11-15 | f863bcf | 1 | Core: Models, Vault, SQLite-Schema V1 + CRUD |
| 2026-11-15 | 0481f96 | 1 | Tests: Vault + Database (10 grün) |
| 2026-11-15 | b927464 | 2 | Naming Engine: Template-Renderer + Sanitizer + Kollision |
| 2026-11-15 | 7d9c134 | 2 | Naming-Tests (15 gesamt grün) |
| 2026-11-15 | 8eff140 | 3 | Ingest: SHA-256-Dedup, PDFKit-Text, Duplikat/Reject |
| 2026-11-15 | 368d123 | 3 | Ingest-Tests mit Fixture-PDFs (20 gesamt grün) |
| 2026-11-15 | 3c601e3 | 4 | OCR: TextRecognizer-Protocol, VisionTextRecognizer, OCRService-Queue |
| 2026-11-15 | 1d34600 | 4 | OCR-Tests (Fake, sync/async) — 24 gesamt grün |
| 2026-11-15 | dcc6e5b | 5 | FTS5-Index (Migration V2 + Trigger) + Such-API mit Filtern |
| 2026-11-15 | 49cc0d8 | 5 | Search-Tests — 29 gesamt grün |
| 2026-11-15 | f451196 | 6 | Core: PDF-Rendering & Thumbnails, tags(for:), onlyNeedsReview-Filter |
| 2026-11-15 | b91cc3f | 6 | Thumbnail-Tests + PDFFixture — 32 gesamt grün |
| 2026-11-15 | 0e68b63 | 6 | App-Shell (SwiftUI): @main, 3 Spalten, Liste+Suche, PDF-Viewer, Thumbnails |
| 2026-11-15 | 32a3d8d | 7 | Core: MetadataService (Speichern + Umbenennen nach Template + Datei-Umzug), Entity-CRUD, moveDocumentFile |
| 2026-11-15 | 7bd94e1 | 7 | Metadata-Tests — 41 gesamt grün |
| 2026-11-15 | 31a3ac2 | 7 | UI: Metadaten-Editor (Bearbeiten/Fertig), Felder+Tags, Verwaltung in Sidebar (Baum, Farben, Kontextmenüs) |
| 2026-11-15 | 73fa0ed | 8 | Core: InboxWatcher (DispatchSource auf inbox/, entprellt, ohne _abgelehnt/) |
| 2026-11-15 | 94fce4c | 8 | InboxWatcher-Tests — 45 gesamt grün |
| 2026-11-15 | cc01369 | 8 | UI: Watcher startet mit App, Drag & Drop PDFs, Menü „Ablage > Importieren…“ |
| 2026-11-15 | 742fc44 | 9 | Core: Heuristik (Datum/Korrespondent/Titel/Kategorie) greift bei Ingest + nach OCR, Datei-Ablage nach documents/YYYY/MM |
| 2026-11-15 | 31df492 | 9 | Heuristik-Tests + Ingest/OCR-End-to-End — 52 gesamt grün |
| 2026-11-15 | 7ba961b | 9 | UI: OCR-Service mit MetadataService verdrahtet |
| 2026-11-15 | 70f62bc | 10 | Core: MCP-Server (JSON-RPC 2.0 stdio, 7 Tools) |
| 2026-11-15 | 240c290 | 10 | MCP-Tests — 59 gesamt grün |
| 2026-11-15 | 1031fc9 | 10 | CLI: `pless mcp --vault <pfad>` startet MCP-Server über stdio |
| 2026-11-15 | 5a3470e | 11 | Core: Vault mit eigenem Import-Ordner (inboxOverride) |
| 2026-11-15 | f28358f | 11 | Vault inboxOverride-Test — 60 gesamt grün |
| 2026-11-15 | 5bd4302 | 11 | UI: Settings (Cmd+,) + Empty States |
| 2026-11-15 | 9e62662 | 12 | Docs: README + Phase 10/11/12 abgehakt |
| 2026-11-15 | a5be7e9 | 12 | build: Scripts/make-app.sh → dist/Pless.app (Release, ad-hoc signiert) |

## Offene Punkte / spätere Ideen
- MCP protocolVersion `2025-06-18` umsetzen
- OCR `accurate` vs. `fast` konfigurierbar
- Kategorie-Vorschlag durch die angebundene KI (MCP-Roundtrip)
- Xcode 27.2 ist installiert (`xcode-select` → `/Applications/Xcode.app`) — volle Toolchain aktiv. `.app`-Packaging ist da: `Scripts/make-app.sh` → `dist/Pless.app` (ad-hoc signiert). Noch offen: Developer-ID-Signing + Share Extension/App Group (braucht Xcode-Projekt, Phase 8) und optional XCTest/Swift Testing statt MiniTest. Quick Look, Menu-Bar-Extra, Export: später
