# pless — Implementierungsplan & Fortschritt

Native macOS-App für lokales Dokumentenmanagement (Paperless, aber lokal & nativ):
PDFs sortieren, per OCR indizieren, anzeigen, mit vernünftigen Dateinamen an einem
Ort ablegen, durchsuchen und über den offenen Standard **MCP** an eine KI anbinden.
Kein Cloud, Single User.

## Festgelegte Architektur-Entscheidungen

| Thema | Entscheidung | Begründung |
|---|---|---|
| Stack | Swift 6.4 + SwiftPM, nur Command Line Tools (kein Xcode nötig) | vorhandenes Setup; `swift build` / `swift test` reichen |
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
- [ ] `@main` App, 3-Spalten-Layout (Sidebar / Liste / Detail)
- [ ] Dokumentliste mit Suchfeld
- [ ] PDF-Viewer (PDFView via NSViewRepresentable)
- [ ] Thumbnails in der Liste

### Phase 7 — Metadaten-Editor
- [ ] Vorschau/Detail: Metadaten read-only; Edit-Modus erst per Klick auf „Bearbeiten“ aktivieren; „Fertig“ speichert + benennt Datei ggf. um
- [ ] Detail: Titel, Datum, Korrespondent, Kategorie, Tags, Notizen
- [ ] Verwaltung: Kategorien (anlegen, umbenennen, Farbe, verschachteln), Tags, Korrespondenten
- [ ] Umbenennen der Datei nach Template

### Phase 8 — Import-Wege
- [ ] Import-Ordner: definierter Ordner (Default `<vault>/inbox`, konfigurierbar), Watch via DispatchSource; neue Dateien laufen automatisch in die Pipeline und werden aus dem Ordner in den Vault verschoben
- [ ] Direkt in die App laden: Drag & Drop auf Fenster/Liste + Menü „Ablage > Importieren…“ (NSOpenPanel, Mehrfachauswahl) → gleicher Ingest-Weg über `inbox/`
- [ ] Apple-Teilen: Share Extension (Target `PlessShare`, ActivationRule für PDFs) schreibt via App Group (shared container + gemeinsame UserDefaults) nach `<vault>/inbox/`; Pipeline übernimmt. Hinweis: Extension erst in signiertem .app produktiv (kommt mit Xcode/Signing später) — Dev-Test über `inbox/`

### Phase 9 — Metadaten-Vorschläge (Heuristik)
- [ ] Datum erkennen (deutsche Formate wie `14.02.2026`)
- [ ] Korrespondent matchen (bekannte Namen im OCR-Text)
- [ ] Titel-Heuristik (erste sinnvolle Zeile)
- [ ] Kategorie-Vorschlag (Schlüsselwörter im OCR-Text; später per KI via MCP)
- [ ] Tests

### Phase 10 — MCP-Server (offener Standard)
- [ ] JSON-RPC 2.0 über stdio: `initialize`, `tools/list`, `tools/call`, `ping`
- [ ] Tools: `search_documents`, `get_document`, `list_documents`, `list_categories`, `update_document`, `assign_tag`, `get_stats`
- [ ] Tests (JSON-RPC-Framing, Tool-Aufrufe)
- [ ] Doku: Einbindung in Claude Desktop / MCP-Clients

### Phase 11 — Settings & Polish
- [ ] Settings: Vault-Pfad, Import-Ordner, Namensschema, OCR-Sprachen, MCP
- [ ] Dark Mode, Empty States, Feinschliff

### Phase 12 — Doku & Übergabe
- [ ] README: Build, Run, Vault, MCP-Config
- [ ] Bekannte Einschränkungen dokumentieren

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

## Offene Punkte / spätere Ideen
- MCP protocolVersion `2025-06-18` umsetzen
- OCR `accurate` vs. `fast` konfigurierbar
- Kategorie-Vorschlag durch die angebundene KI (MCP-Roundtrip)
- Xcode wird später zu Hause installiert — dann .app-Packaging + Signing (Share Extension, App Group) und optional XCTest/Swift Testing statt MiniTest; bis dahin CLT-only. Quick Look, Menu-Bar-Extra, Export: später
