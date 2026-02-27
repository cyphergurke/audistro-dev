# Production TODOs

Stand: 2026-02-27

Diese Liste fokussiert nur produktionsrelevante Lücken.  
System- und Architekturkontext: `docs/architecture.md`, `docs/system-status.md`.

## Pflege-Regel

- Jede neue nicht-produktionsreife Abweichung wird im selben Change hier ergänzt.
- Jeder Eintrag enthält:
  - Risiko
  - gewünschter Zielzustand
  - Exit-Kriterium

## Bereits erreicht (nicht mehr Blocker)

- Device-bound Access Flow in FAP (`bootstrap -> challenge -> token -> key`).
- Access Grants mit Aktivierung beim ersten Key-Fetch.
- Boost APIs inkl. Listing/Status.
- Device-scoped Ledger.
- Web Spend Dashboard (`/me/spend`).
- FAP Rate limits (challenge/token/key) + webhook dedupe.

## P0 – Blocker vor Produktionsfreigabe

### 1) Transport- und Announce-Pfad ohne DB-Bypass

Risiko:

- Der aktuelle Dev-Smoke nutzt noch provider-registry Upserts in Catalog als Fallback.
- Das umgeht den realen signed announce Pfad.

Zielzustand:

- Provider werden in allen Umgebungen ausschließlich über den offiziellen Announce-Flow registriert.
- Kein direkter SQL-Upsert im normalen Test-/Betriebspfad.

Exit-Kriterium:

- `scripts/smoke-e2e-playback.sh` läuft ohne registry-upsert fallback.
- First-provider-failover-Test bleibt dabei stabil grün.

### 2) HTTPS-first Policy für Stage/Prod

Risiko:

- In dev sind HTTP-Ausnahmen vorhanden; ohne klare Trennung droht Konfig-Drift in Richtung Prod.

Zielzustand:

- Stage/Prod strikt `https` end-to-end (Catalog, FAP, Provider, Web).
- Insecure Flags nur für lokale Dev-Umgebung.

Exit-Kriterium:

- Stage-Smoke und Prod-Precheck laufen ohne HTTP-Ausnahmen.
- Config-Gates verhindern unsichere Deployments.

### 3) Zahlungssettlement robust und deterministisch

Risiko:

- Verzögerte/fehlende Webhooks führen zu UI-Timeouts oder inkonsistentem Zustand.

Zielzustand:

- Primärer Settlementpfad ist webhook-stabil, replay-safe und operational sichtbar.
- Fallback-Verhalten klar definiert (kein stilles Hängen).

Exit-Kriterium:

- Wiederholte End-to-End-Läufe zeigen konsistente Übergänge:
  `pending -> paid -> token -> key`.
- Operational Alerts für webhook-/token failure spikes vorhanden.

### 4) Produktionshärtung für Dev/Admin-Pfade

Risiko:

- Dev-Endpunkte dürfen nicht versehentlich in Prod aktiv sein.

Zielzustand:

- Dev-only Features strikt und automatisiert abgeschaltet:
  - FAP `POST /v1/access/{assetId}`
  - FAP `POST /v1/boost/{boostId}/mark_paid`
  - Web `/admin/payees`

Exit-Kriterium:

- CI/Startup checks schlagen fehl, falls dev-only in Prod aktiv.

## P1 – Hohe Priorität nach P0

### 5) Observability und Runbooks

- Metriken/Alerts für:
  - challenge create failures
  - token exchange conflicts/errors
  - key endpoint 401/403/429
  - announce failures
- Runbooks:
  - "payment settled but token not issued"
  - "provider announce failed"
  - "grant expired unexpectedly"

### 6) Security Review der SSRF- und URL-Policies

- Web server routes erneut auditen:
  - nur trusted upstream derivation
  - keine clientseitigen URL-overrides
- FAP outbound policy für LNbits URLs auf allowlist/tenant policy prüfen.

### 7) Schema-/Migration-Betriebshärtung

- Migrationskette auf langlebige Upgrades testen (bestehende Datenstände).
- Roll-forward-Strategie dokumentieren.
- Backup/restore Testlauf für `audicatalog` und `fap` SQLite.

## P2 – Produktisierung / Skalierung

### 8) Account-/Identity-Roadmap

- Entscheidung: device-only bleibt v1 oder Mapping auf User-Account.
- Falls User-Accounts kommen:
  - Migrationpfad für bestehende device-scoped Ledgerdaten.

### 9) Multi-region und Provider-Qualität

- Qualitätsmetriken pro Provider (timeout/error rates) in Ranking einfließen lassen.
- Regionale Failover-Strategie dokumentieren.

### 10) Compliance/Retention

- Aufbewahrung für Ledger/Webhook-Events gegen fachliche Anforderungen prüfen.
- Datenlösch-/Exportpfade definieren.

## Konkrete nächste Schritte (empfohlen)

1. Remove DB-upsert fallback im Playback-Smoke; auf echten announce-only Pfad umstellen.
2. TLS-fähigen Stage-Stack aufsetzen und End-to-End Smoke dort fixieren.
3. Operational Alerts + mindestens zwei Runbooks produktionsreif ausrollen.
