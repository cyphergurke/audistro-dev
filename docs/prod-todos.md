# Production TODOs

Stand: 2026-03-02

Diese Liste enthält nur reale Produktionslücken auf Basis des aktuellen Repo-Stands nach Phase 3 sowie Phase 2.1/2.2.
Bereits umgesetzte Punkte bleiben knapp als `done` markiert, damit offene Lücken klar von erledigter Härtung getrennt sind.

## Security

- `[done]` `GET /internal/assets/{assetId}/packaging-key` in FAP ist per CIDR-Restriktion und `FAP_ADMIN_TOKEN` geschützt und getestet.
  Acceptance criteria: FAP-Tests decken `missing token`, `disallowed CIDR` und die Rückgabe von genau 16 Byte erfolgreich ab.

- `[done]` Dev-/Admin-Flächen sind per Env-Gates im Code abgeschaltet, wenn der Dev-Modus nicht aktiv ist.
  Acceptance criteria: Web `/admin/*`, Catalog `/v1/admin/*` und FAP-Dev-Endpunkte liefern im Prod-Modus keine nutzbare Admin-Funktionalität mehr.

- `[done]` FAP, Catalog und Provider failen jetzt hart bei unsicheren Prod-Defaults, soweit die aktuellen Konfigurationsmodelle es erlauben.
  Acceptance criteria: `FAP_DEV_MODE=false` ohne `FAP_INTERNAL_ALLOWED_CIDRS`, `CATALOG_ENV=dev` ohne `CATALOG_ADMIN_TOKEN` und `PROVIDER_INTERNAL_ENABLE=true` ohne `PROVIDER_INTERNAL_ALLOWED_CIDRS` brechen den Start deterministisch ab.

- `[done]` Dev-/Admin-Endpunkte sind in Prod hart deaktiviert oder am Edge blockiert.
  Acceptance criteria: Catalog registriert `/v1/admin/*` in Prod nicht, Web-Dev-Admin bleibt aus, und der Caddy-Referenz-Stack blockiert `/catalog/v1/admin/*` sowie `/internal/*` bereits am Edge.

- `[open]` Webhook-Härtung ist funktional vorhanden, aber Allowlist- und Secret-Rotation sind noch kein verifizierter Betriebsprozess.
  Acceptance criteria: Für jeden externen Webhook sind Secret-Rotation und optionaler Source-Allowlist-Check dokumentiert und einmal in Staging erfolgreich durchgespielt.

- `[open]` Ein Repo-/CI-Gate gegen eingecheckte Secrets fehlt weiterhin.
  Acceptance criteria: CI schlägt fehl, wenn neue Klartext-Secrets, Wallet-Keys oder `.env`-Geheimnisse committed werden.

## Reliability

- `[done]` Repo-weite CI-Gates für Unit-, Web- und Smoke-Checks existieren und laufen lokal sowie in GitHub Actions.
  Acceptance criteria: `./scripts/ci-gates.sh unit` und `CI=1 SKIP_MANUAL=1 ./scripts/ci-gates.sh smoke` laufen auf einer sauberen Maschine reproduzierbar durch.

- `[open]` Der Catalog-Ingest-Worker hat noch keine explizite Retry-/Dead-letter-Strategie für dauerhaft fehlschlagende Jobs.
  Acceptance criteria: Wiederholt fehlschlagende `ingest_jobs` werden nach einer begrenzten Retry-Zahl in einen klaren Endzustand überführt und können getrennt von normalen Queues ausgewertet werden.

- `[done]` Die Publish-/Announce-Logik repliziert Assets regulär auf `eu_1` und `eu_2`; der verschlüsselte Failover-Smoke arbeitet ohne manuelle Kopierschritte.
  Acceptance criteria: Ein normaler Upload veröffentlicht Assets automatisch auf mindestens zwei Provider, und `smoke-encrypted-failover.sh` benötigt keine manuelle Dateikopie mehr.

- `[open]` `audistro-catalog` und `audistro-fap` haben noch keinen explizit getesteten Graceful-Shutdown-Pfad unter SIGTERM.
  Acceptance criteria: Ein SIGTERM-Test beendet beide Prozesse innerhalb des konfigurierten Fensters ohne beschädigte SQLite-Dateien oder verlorene Inflight-Arbeit.

## Observability

- `[done]` Access-Logs existieren in Provider, Catalog und FAP; Provider exportiert bereits Prometheus-Metriken.
  Acceptance criteria: Jeder HTTP-Request erzeugt einen Logeintrag mit Methode, Pfad, Status und Latenz, und Provider liefert `GET /metrics`.

- `[open]` Catalog und FAP haben noch keine eigenen Metrik-Endpunkte oder Exporter für ingest-, payment- und key-relevante Counters.
  Acceptance criteria: Catalog und FAP liefern scrape-bare Metriken für Ingest-Status, Challenge/Token-Flows, Key-Endpoint-Erfolge/Rejects und interne Fehler.

- `[done]` Operative Runbooks für Backup/Restore, Secret-Rotation und Incident-Triage existieren jetzt.
  Acceptance criteria: Die Runbooks dokumentieren konkrete Schritte für Restore, Rotation und Diagnose der aktuellen Payment-, Key-, Ingest- und Announce-Pfade.

- `[open]` Alerting und die neuen Runbooks sind noch nicht als echter Betriebsablauf in Staging validiert.
  Acceptance criteria: Für Ingest-Fehler, Payment-/Webhook-Störungen, Key-Endpoint-Rejects und Provider-Announce-Drift existieren Alerts und mindestens ein dokumentierter Staging-Drill.

## Networking/Deployment

- `[done]` Eine gehärtete Referenz für TLS-Termination und internes Service-Routing liegt mit `docker-compose.prod.yml` und Caddy vor.
  Acceptance criteria: `docker-compose.prod.yml`, `caddy/Caddyfile` und `docs/deploy-prod.md` beschreiben denselben Routing- und Netzpfad konsistent.

- `[open]` Der Prod-Predeploy-Check für öffentliche URLs, TLS-Zwang und das Verbot von `localhost`/`http://` ist noch nicht automatisiert.
  Acceptance criteria: Ein Predeploy-Check schlägt fehl, wenn Prod-Configs `localhost`, `http://` oder leere `*_PUBLIC_BASE_URL` enthalten.

- `[done]` Provider-`/metrics` sind in der Referenz am Edge blockiert und nur noch als privater Scrape-Pfad gedacht.
  Acceptance criteria: Externe Requests auf Provider-`/metrics` liefern `403` oder `404`, während internes Scraping weiter funktioniert.

- `[open]` Der Prod-Referenz-Stack ist noch nicht als echter Edge-Test mit externem Hostrouting verifiziert.
  Acceptance criteria: Ein automatisierter Test gegen den Caddy-Stack bestätigt `/catalog/*`, `/fap/*`, Provider-Hosts und die Blockade von `/internal/*` unter der echten Edge-Struktur.

## Testing/CI

- `[done]` Die relevanten Dev-/Integration-Smokes für Playback, paid access, encrypted ingest und encrypted failover existieren und sind im Gate-Skript verdrahtet.
  Acceptance criteria: Die Smoke-Skripte laufen einzeln und werden von `scripts/ci-gates.sh` referenziert.

- `[open]` Die bezahlungsabhängigen Smokes dürfen in CI noch skippen, wenn LNbits-/Payer-Secrets fehlen; ein verpflichtender Secret-bestückter Gate-Job fehlt.
  Acceptance criteria: Es existieren zwei klar getrennte CI-Pfade: ein öffentlich lauffähiger Skip-Pfad ohne Secrets und ein geschützter Pflicht-Job mit echten LNbits-Secrets, der `smoke-paid-access.sh` und `smoke-upload-encrypt-pay.sh` grün ausführt.

- `[open]` Browser-Playback ist trotz UI-Preflight weiter nur manuell als echtes Decode-/Fallback-Verhalten validiert.
  Acceptance criteria: Ein Browser-basierter Test bestätigt für ein verschlüsseltes Asset mindestens einmal den Übergang bis `Playing` inklusive Provider-Fallback.

- `[open]` Die OpenAPI-/Contract-Validierung ist serviceübergreifend nicht vollständig abgesichert.
  Acceptance criteria: Für FAP, Provider und Catalog ist im CI nachweisbar, dass Router, ausgelieferte OpenAPI-Spezifikation und dokumentierte Requests/Responses nicht auseinanderlaufen.

- `[open]` Der Prod-Referenz-Stack ist noch kein blocking CI-Gate.
  Acceptance criteria: Mindestens ein separater CI-Job bootet den Prod-Referenz-Stack, führt Edge-/Security-Checks aus und blockiert bei Abweichungen den Build.

- `[done]` Ein nächtlicher Restore-Drill ist als eigener CI-Pfad vorbereitet.
  Acceptance criteria: Ein geplanter oder manuell gestarteter CI-Job führt `scripts/backup-restore-drill.sh` aus und skippt sauber, wenn die bezahlte Baseline mangels Secrets nicht erzeugt werden kann.

## Data/Backups

- `[done]` Backup/Restore für die SQLite-Volumes ist dokumentiert und als automatisierbarer Drill vorhanden.
  Acceptance criteria: `scripts/backup-restore-drill.sh` bringt den Stack aus gesicherten Catalog-, FAP-, Provider- und LNbits-Volumes reproduzierbar in einen grünen Zustand zurück.

- `[done]` Es gibt jetzt einen dokumentierten und skriptbaren Datenintegritäts-Check nach Restore für die wichtigsten Tabellen und Provider-Asset-Bestände.
  Acceptance criteria: Nach einem Restore vergleicht der Drill mindestens FAP-`ledger_entries`, Catalog-`assets`, Catalog-`ingest_jobs` und Provider-Asset-Verzeichnisse gegen definierte Sollwerte.

- `[open]` Secret- und Key-Rotation ist für persistierte Daten nur teilweise beschrieben; insbesondere eine spätere `FAP_MASTER_KEY_HEX`-Rotation ist noch nicht operationalisiert.
  Acceptance criteria: Es existiert ein dokumentierter und testbarer Rotationspfad für Admin-Tokens, Webhook-Secrets und eine zukünftige Master-Key-Rotation ohne Datenverlust.
