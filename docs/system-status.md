# Systemstatus (Ist-Stand)

Stand: 2026-02-27

## 1. Gesamtfazit

Das System ist funktional als Dev- und Integrationsplattform:

- Playback-Ende-zu-Ende läuft mit Provider-Fallback.
- Non-dev Access-Payment-Flow ist implementiert (Challenge -> Payment -> Token -> Key).
- Boost + Boost-Historie sind implementiert.
- Device-scoped Ledger und Spend-Dashboard sind implementiert.

Es gibt weiterhin klare Production-Blocker (siehe `docs/prod-todos.md`).

## 2. Implementierte Fähigkeiten

### 2.1 Playback und Provider

- Catalog liefert Provider-Hints für Asset-Playback.
- Web-Player nutzt geordnete Provider-Liste.
- Fehlerklassifikation in der UI (Manifest/Fragment/Key/Media).
- deterministische Fallback-Logik mit begrenzten Switches.

### 2.2 Access Payments

- Device bootstrap via Cookie (`fap_device_id`).
- FAP Challenge-/Token-Flow in non-dev.
- Grant-Aktivierung beim ersten erfolgreichen Key-Request.
- Key-Gating über Token + Device + Grant.

### 2.3 Boost

- Invoice-Generierung.
- Polling auf Status.
- Dev fallback `mark_paid`.
- FAP list/get APIs für Boost-Audit.

### 2.4 Ledger / Transparenz

- Normalisierte Ledger-Einträge für Access und Boost.
- Device-scoped Listing mit Cursor-Pagination.
- Web Spend-Dashboard:
  - Access vs Boost totals
  - Top assets
  - Top payees
  - Zeitfenster 7d/30d

### 2.5 Security/Hardening (bereits umgesetzt)

- SSRF-sichere Server-Routen im Web.
- Rate limits in FAP (challenge/token/key).
- Webhook-Replay-Dedupe.
- Token- und Device-Bindung für HLS-Key-Zugriff.

## 3. Betriebsstatus der Services

- `audicatalog`: stabil, Metadaten-Source of Truth.
- `audiprovider`: stabil, HLS Serving + announce/rescan intern.
- `fap`: stabil nach Migrations-Fix (device/ledger schema chain).
- `web`: stabil, neue Routen für Access/Boost/Spend vorhanden.
- `lnbits`: im Compose integriert, Dev-Zahlungsbackend.

## 4. Bekannte Schwachstellen / Risiken

- Transport/Announce-Pfad ist noch nicht vollständig prod-rein:
  - Dev-Smoke verwendet weiterhin DB-Upsert-Fallback im Catalog-Pfad.
- TLS-Policy ist nicht in allen Umgebungen konsequent vereinheitlicht.
- Device-scope statt Account-scope:
  - erwartet für frühe Phase, aber begrenzt User-Portabilität.

## 5. Empfohlene nächste Schritte

1. P0 aus `docs/prod-todos.md` abarbeiten (TLS + announce ohne DB bypass).
2. Smoke-Pfade auf echten signed announce ohne fallback umstellen.
3. Ops-Härtung erweitern:
   - Monitoring/Alerting für settle/token/key failure rates.
   - Runbooks für payment settlement delays und announce errors.
