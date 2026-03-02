# Systemarchitektur (Ist-Stand)

Stand: 2026-02-27

## 1. Zweck des Systems

`audiostr` ist ein verteiltes Audio-Streaming-System mit Zahlungs-Gating.

Kernziele:

- Multi-Provider HLS-Playback mit Fallback.
- Pay-per-access über Lightning (LNbits/OpenNode im Dev-Setup).
- Boost/Tip-Flows.
- Device-scope Transparenz über ein Ledger ("Where did my money go").

## 2. Deploy-Topologie (Dev Compose)

Aktuelle Compose-Services:

- `audicatalog` (`localhost:18080`)
- `fap` (`localhost:18081`)
- `audiprovider_eu_1` (`localhost:18082`)
- `audiprovider_eu_2` (`localhost:18083`)
- `audiprovider_us_1` (`localhost:18084`)
- `web` (`localhost:3000`)
- `lnbits` (`localhost:18090`)

Persistente Volumes:

- `audicatalog_data`
- `fap_data`
- `lnbits_data`
- `audiprovider_*_data`

## 3. Komponenten und Verantwortlichkeiten

### 3.1 audicatalog (Source of Truth für Metadaten)

Verantwortung:

- Künstler/Assets/Payees.
- Provider-Registry und Provider-Hints für Playback-Ranking.
- Playback-Bootstrap-Response (`/v1/playback/{assetId}`).

Relevante Playback-Felder:

- `asset.pay.fap_url`
- `asset.pay.payee_id`
- `asset.pay.fap_payee_id`
- `asset.pay.price_msat`
- `asset.hls.key_uri_template`
- `providers[]` (ranked)

### 3.2 audiprovider (HLS Serving)

Verantwortung:

- Auslieferung von `master.m3u8` und Segmenten.
- optional Proxy/Hybrid-Origin-Modus.
- interne Endpoints für `rescan` + `announce`.

### 3.3 fap (Payment, Policy, Gate)

Verantwortung:

- Device Identity via `fap_device_id` Cookie.
- Access Challenge + Token Exchange.
- Access Grants (Aktivierung beim ersten Key-Fetch).
- HLS-Key-Gating (`/hls/{assetId}/key`).
- Boost-Erstellung/Status/List.
- Device-scoped Ledger.
- LNbits Webhook Settlement + Replay-Schutz.
- Endpoint-spezifische Rate Limits (device-first, IP fallback).

### 3.4 web (Next.js App Router)

Verantwortung:

- Fan UI (`/`, `/asset/[assetId]`, `/me/spend`).
- Server-side Proxy-Routen (SSRF-sicher).
- adaptive Access-Flows (dev/non-dev).
- Playlist-Rewrite und Key-Proxy (`/api/hls-key/[assetId]`).
- Boost UI + History.
- Spend Dashboard Aggregation.

Wichtiger Security-Ansatz:

- Client sendet keine Upstream-URLs.
- URLs werden serverseitig aus trusted Catalog-Daten abgeleitet.

### 3.5 lnbits (Lightning Backend im Dev-Stack)

Verantwortung:

- Invoice-Erstellung und Payment-Status.
- Webhook-Events Richtung FAP.

## 4. Datenhoheit und Datenmodelle

### 4.1 Hoheit

- `audicatalog`: Asset/Artist/Payee-Metadaten und Pricing-Hints.
- `fap`: Zahlungs-/Access-Policy, Device-Bindung, Ledger Ground Truth.
- `audiprovider`: Content-Availability und HLS-Auslieferung.

### 4.2 Kritische FAP-Modelle (vereinfacht)

- `devices`: pseudonyme Device-Identität.
- `challenges`: Access-Challenges inkl. LNbits-Referenzen.
- `access_grants`: kaufbezogene Zugriffsdauer, aktiviert beim ersten Key-Fetch.
- `boosts`: tip/boost Zahlungen inkl. Settlement-Status.
- `ledger_entries`: normalisiertes Journal (`access` + `boost`).
- `webhook_events`: Dedupe für Webhook-Replays.

## 5. Laufzeit-Flows

### 5.1 Playback Bootstrap + Provider Fallback

1. UI ruft `/api/playback/{assetId}`.
2. Catalog liefert ranked `providers`.
3. UI fordert Access (`/api/access/{assetId}`).
4. UI lädt Playlist via `/api/playlist/{assetId}?providerId=...&token=...`.
5. Route validiert `providerId` gegen Catalog-Playback.
6. Route rewritet Key-URI auf same-origin `/api/hls-key/{assetId}?token=...`.
7. Player fallbackt bei Manifest/Fragment-Fehlern auf nächsten Provider.

### 5.2 Non-Dev Pay-per-access

1. Device bootstrap (`/api/device/bootstrap` -> FAP Cookie).
2. Access Challenge (`/v1/fap/challenge`) erzeugt Invoice.
3. Zahlung via LNbits.
4. Webhook markiert Challenge als paid.
5. Token Exchange (`/v1/fap/token`) liefert Access Token.
6. Erster Key-Fetch aktiviert Grant (`valid_from`, `valid_until`).

### 5.3 Boost/Tip

1. UI generiert Boost-Invoice (`/api/boost`).
2. Polling über `/api/boost/{boostId}`.
3. Settlement via LNbits/Webhook oder Dev `mark_paid`.
4. Historie via `/api/boost/list`.

### 5.4 Fan Transparency / Spend Dashboard

1. UI lädt `/api/me/spend-summary`.
2. Server nutzt primär `GET /v1/ledger/summary` (device-scoped via `fap_device_id` Cookie).
3. Fallback: Pagination über `GET /v1/ledger` falls Summary nicht verfügbar.
4. Aggregation:
   - access vs boost totals
   - top assets
   - top payees
5. Label-Enrichment über Catalog Asset-Lookups.

## 6. Security-Modell (Ist)

Transport:

- Dev läuft überwiegend über HTTP.
- Prod-Ziel bleibt HTTPS end-to-end.

Identity/Session:

- Device-ID im httpOnly Cookie.
- Token-Subjekt muss zu Device passen.

Gating:

- `/hls/{assetId}/key` erfordert gültiges Token und aktiven Grant.

Abuse-Controls:

- Rate limits auf Challenge/Token/Key.
- Webhook Signature + Replay-Dedupe.
- SSRF-Schutz in Web Server-Routen.

Secrets:

- Token secret via Secret-File.
- Master Key / Issuer Key via Env.
- LNbits Keys payee-scoped im FAP-Storage (encrypted at rest).

## 7. Betriebs- und Testmodell

Verfügbare Smoke-Tests:

- `scripts/smoke-e2e-playback.sh`
- `scripts/smoke-paid-access.sh`

Wichtige Diagnose-Dokus:

- `docs/smoke-e2e.md`
- `docs/smoke-paid-access.md`
- `docs/ui.md`
- `analysis-streambug.md`

## 8. Bekannte Architektur-Lücken Richtung Produktion

- Dev-Smoke nutzt aktuell noch provider-registry Direkt-Upserts als Fallback bei HTTP-Announce-Constraints.
- TLS-Strategie ist in Dev/Stage/Prod noch nicht einheitlich finalisiert.
- Kein User-Account-Modell (bewusst), aktuell device-scope only.
- Admin-Endpunkte/Dev-Admin müssen für echte Prod-Deployments stärker abgeschottet werden.

## 9. Zielbild (kurz)

- HTTPS-only für Stage/Prod, inklusive Provider-Announce.
- Kein DB-Bypass im regulären Betriebs-/Smoke-Pfad.
- Stabile LNbits/Webhook Settlement Chain ohne fallback hacks.
- Transparente Fan-Ledger-Views mit robuster Auditierbarkeit.
