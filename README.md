# pless

<img src="docs/pless-app-icon-svg.svg" width="128" alt="pless Icon">

Native macOS-App für lokales Dokumentenmanagement — Paperless, aber lokal & nativ:
PDFs importieren, per On-Device-OCR indizieren, an einem Ort mit vernünftigen
Dateinamen ablegen, durchsuchen und über **MCP** an eine lokale KI anbinden.
Kein Cloud, Single User.

## Was pless kann

- **Import:** PDFs per Drag & Drop, über „Ablage > Importieren…“ oder automatisch aus
  dem Posteingang (`inbox/`); Duplikate werden erkannt und landen in `_abgelehnt/`.
- **OCR & Suche:** Texterkennung direkt auf dem Mac (Vision, de/en) und
  Volltextsuche über Titel, OCR-Text und Korrespondent — alles in einer lokalen Datenbank.
- **Ablage & Metadaten:** PDFs landen in `documents/YYYY/MM/` mit Namen nach Schema
  (`{date}_{correspondent}_{title}.pdf`); Titel, Datum, Korrespondent, Kategorie, Tags
  und Notizen bequem in der App bearbeiten, dazu Thumbnails und eine Detailansicht.
- **KI-Anbindung:** eigener MCP-Server über stdio — eine lokale KI kann Dokumente
  suchen/lesen, Metadaten ändern und Tags zuweisen (Config unten).
- **paperless-ngx Sync (opt-in):** Push zu einer selbst gehosteten paperless-Instanz,
  inkl. Import von Kategorien/Korrespondenten und Wolken-Symbol pro PDF —
  Details im [eigenen Abschnitt](#paperless-ngx-sync-opt-in) unten.

## paperless-ngx Sync (opt-in)

Auf Wunsch spiegelt pless deine Dokumente zu einer selbst gehosteten
[paperless-ngx](https://docs.paperless-ngx.com/)-Instanz. Ohne konfigurierte URL und
API-Token (Einstellungen → paperless-ngx; das Token liegt sicher im macOS-Schlüsselbund)
passiert nie ein Netzwerk-Call.

**Was der Sync kann:**

- **Push:** neue und geänderte PDFs werden hochgeladen — mit Titel, Datum, Korrespondent
  (→ paperless-Correspondent), Kategorie (→ paperless-Document-Type) und Tags.
  Fehlende Correspondents, Document Types und Tags werden in paperless automatisch angelegt.
- **Idempotent:** doppelte Uploads werden per Checksumme erkannt. Ändert sich die Datei,
  gibt es einen Re-Upload; ändern sich nur die Metadaten (Titel, Datum, Kategorie …),
  wird das bestehende Dokument in paperless per PATCH aktualisiert — ohne Re-Upload.
- **Metadaten erzwingen:** per Dropdown am Sync-Button (Toolbar) oder Menü in den
  Dokument-Details lassen sich die Metadaten gezielt erneut pushen, z. B. um eine falsch
  zugeordnete Kategorie zu korrigieren.
- **Import aus paperless:** alle Document Types und Correspondents der paperless-Instanz
  lassen sich als Kategorien und Korrespondenten nach pless übernehmen (ebenfalls über
  das Sync-Dropdown).
- **Sync-Stand pro PDF:** jede Dokumentkarte zeigt oben rechts eine Wolke — grün =
  synchronisiert, orange = offen (z. B. nach Metadaten-Änderung oder fehlgeschlagenem
  Push), grau = unbekannt (Sync nicht konfiguriert oder nie gelaufen). Dieselbe Anzeige
  gibt es in der Detailansicht.

Technischer Hintergrund (Mapping, Checksumme, PATCH, Pull): [docs/technik.md](docs/technik.md).

## Build & Test (Xcode installiert, SwiftPM-only — kein Xcode-Projekt nötig)

```bash
swift build --package-path /Users/ptc/dev/ppless
swift run   --package-path /Users/ptc/dev/ppless PlessTests                # Tests (Exit-Code 0 = grün)
swift run   --package-path /Users/ptc/dev/ppless Pless                       # App (GUI)
swift run   --package-path /Users/ptc/dev/ppless Pless --vault <pfad>        # App mit anderem Vault
swift run   --package-path /Users/ptc/dev/ppless Pless mcp --vault <pfad>    # MCP-Server (stdio)
```

## App-Bundle (.app)

```bash
bash Scripts/make-app.sh        # Release-Build + Bundle + Signing → dist/Pless.app
open dist/Pless.app             # starten (oder nach /Applications kopieren)
```

`dist/` liegt nicht im git.

## Ablage (Vault)

Alles liegt in einem Ordner (Default `~/Documents/Pless`, in den Einstellungen änderbar):
`pless.db` (lokale Datenbank), `documents/YYYY/MM/` (die PDFs), `inbox/` (Import-Ordner),
`thumbnails/` (Cache). Details zum Layout und Schema: [docs/technik.md](docs/technik.md).

## MCP-Anbindung (lokale KI, z. B. Claude Desktop)

`pless mcp --vault <pfad>` stellt der KI Werkzeuge bereit: Dokumente suchen und lesen,
Metadaten aktualisieren, Tags zuweisen, Statistiken abrufen.

Config-Snippet (auch in den App-Settings unter „MCP“ zum Kopieren):

```json
{
  "mcpServers": {
    "pless": {
      "command": "<Pfad-zum-Binary>/Pless",
      "args": ["mcp", "--vault", "/Users/ptc/Documents/Pless"]
    }
  }
}
```

## Doku

- [docs/technik.md](docs/technik.md) — technischer Hintergrund: Architektur, Datenbank-Schema
  und Migrationen, Sync-Design (Push/Pull/PATCH), MCP-Protokoll, Tests, App-Bundle
- [docs/implementierung.md](docs/implementierung.md) — Roadmap & Fortschritts-Log
- `AGENTS.md` — Vorgehen & Konventionen im Repo

## Lizenz

pless ist Open Source unter **GPL-3.0-or-later** — siehe [LICENSE](LICENSE)
(SPDX: `GPL-3.0-or-later`). **Forks sind ausdrücklich willkommen**; Änderungen an einem
Fork fallen automatisch unter dieselbe Lizenz. Externe Commits/PRs werden nicht angenommen.

**Kommerzielle Lizenz (Dual Licensing):** Der Autor ist alleiniger Copyright-Holder und
bietet auf Anfrage eine kommerzielle Lizenz an — für Firmen, die pless geschlossen einsetzen
oder ohne Source-Offenlegung vertreiben wollen. Kontakt: dev@ptch.de

Externe Abhängigkeiten hat pless keine: nur Apple-System-Frameworks (dynamisch aus macOS
geladen, nicht mit der App verteilt) und die systemeigene SQLite (Public Domain).

## Bekannte Einschränkungen

- Share Extension (Apple-Teilen) fehlt noch — geteilte PDFs landen manuell im Posteingang.
- Kein Papierkorb in der UI (Soft Delete ist im Schema vorbereitet).
- Der paperless-Sync ist ein Einweg-Push: Änderungen, die direkt in paperless-ngx
  gemacht werden, spiegelt pless nicht zurück.
- OCR: Sprachen (de/en), Genauigkeit (genau/schnell), Sprachkorrektur und Auflösung (dpi)
  sind in den Einstellungen konfigurierbar — „genau“ + höhere dpi erkennen kleine Schrift besser.
