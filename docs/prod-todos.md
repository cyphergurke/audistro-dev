# Production TODOs

Stand: 2026-03-02

Diese Liste enthält nur reale Produktionslücken auf Basis des aktuellen Repo-Stands nach Phase 3 sowie Phase 2.1/2.2.
Bereits umgesetzte Punkte bleiben knapp als `done` markiert, damit offene Lücken klar von erledigter Härtung getrennt sind.

## Security

- `[done]` `GET /internal/assets/{assetId}/packaging-key` in FAP ist per CIDR-Restriktion und `FAP_ADMIN_TOKEN` geschützt und getestet.
  Acceptance criteria: FAP-Tests decken `missing token`, `disallowed CIDR` und die Rückgabe von genau 16 Byte erfolgreich ab.

- `[done]` Dev-/Admin-Flächen sind per Env-Gates im Code abgeschaltet, wenn der Dev-Modus nicht aktiv ist.
  Acceptance criteria: Web `/admin/*`, Catalog `/v1/admin/*` und FAP-Dev-Endpunkte liefern im Prod-Modus keine nutzbare Admin-Funktionalität mehr.

- `[open]` Prod-Configs failen noch nicht hart, wenn interne CIDRs, Admin-Tokens oder Master-Secrets leer/unsicher gesetzt sind.
  Acceptance criteria: Ein Prod-Start oder Predeploy-Check bricht deterministisch ab, wenn `*_ADMIN_TOKEN`, `FAP_MASTER_KEY_HEX` oder interne CIDR-Restriktionen fehlen oder offensichtlich unsicher sind.

- `[open]` Dev-/Admin-Endpunkte sind in Prod nur per Runtime-Gate gesperrt, aber nicht zusätzlich hart deaktiviert oder im Edge explizit blockiert.
  Acceptance criteria: Im Prod-Referenz-Stack liefern `/admin/*` und nicht öffentliche `/internal/*` unabhängig von Applikations-Flags bereits am Edge `403` oder `404`.

- `[open]` Webhook-Härtung ist funktional vorhanden, aber Allowlist- und Secret-Rotation sind noch kein verifizierter Betriebsprozess.
  Acceptance criteria: Für jeden externen Webhook sind Secret-Rotation und optionaler Source-Allowlist-Check dokumentiert und einmal in Staging erfolgreich durchgespielt.

- `[open]` Ein Repo-/CI-Gate gegen eingecheckte Secrets fehlt weiterhin.
  Acceptance criteria: CI schlägt fehl, wenn neue Klartext-Secrets, Wallet-Keys oder `.env`-Geheimnisse committed werden.

## Reliability

- `[done]` Repo-weite CI-Gates für Unit-, Web- und Smoke-Checks existieren und laufen lokal sowie in GitHub Actions.
  Acceptance criteria: `./scripts/ci-gates.sh unit` und `CI=1 SKIP_MANUAL=1 ./scripts/ci-gates.sh smoke` laufen auf einer sauberen Maschine reproduzierbar durch.

- `[open]` Der Catalog-Ingest-Worker hat noch keine explizite Retry-/Dead-letter-Strategie für dauerhaft fehlschlagende Jobs.
  Acceptance criteria: Wiederholt fehlschlagende `ingest_jobs` werden nach einer begrenzten Retry-Zahl in einen klaren Endzustand überführt und können getrennt von normalen Queues ausgewertet werden.

- `[open]` Die Publish-/Announce-Logik repliziert Assets noch nicht regulär auf mehrere Provider; der verschlüsselte Failover-Smoke arbeitet dev-only mit Kopier-/Rescan-Hilfen.
  Acceptance criteria: Ein Asset kann über normale Worker-/Publish-Pfade auf mindestens zwei Provider verteilt und ohne manuelle Dateikopien im Playback verwendet werden.

- `[open]` `audistro-catalog` und `audistro-fap` haben noch keinen explizit getesteten Graceful-Shutdown-Pfad unter SIGTERM.
  Acceptance criteria: Ein SIGTERM-Test beendet beide Prozesse innerhalb des konfigurierten Fensters ohne beschädigte SQLite-Dateien oder verlorene Inflight-Arbeit.

## Observability

- `[done]` Access-Logs existieren in Provider, Catalog und FAP; Provider exportiert bereits Prometheus-Metriken.
  Acceptance criteria: Jeder HTTP-Request erzeugt einen Logeintrag mit Methode, Pfad, Status und Latenz, und Provider liefert `GET /metrics`.

- `[open]` Catalog und FAP haben noch keine eigenen Metrik-Endpunkte oder Exporter für ingest-, payment- und key-relevante Counters.
  Acceptance criteria: Catalog und FAP liefern scrape-bare Metriken für Ingest-Status, Challenge/Token-Flows, Key-Endpoint-Erfolge/Rejects und interne Fehler.

- `[open]` Alerting und Runbooks für die neuen Encrypted-Ingest-/Failover-Pfade sind noch nicht als Betriebsablauf validiert.
  Acceptance criteria: Für Ingest-Fehler, Payment-/Webhook-Störungen, Key-Endpoint-Rejects und Provider-Announce-Drift existieren Alerts und ein dokumentierter Staging-Drill.

## Networking/Deployment

- `[done]` Eine gehärtete Referenz für TLS-Termination und internes Service-Routing liegt mit `docker-compose.prod.yml` und Caddy vor.
  Acceptance criteria: `docker-compose.prod.yml`, `caddy/Caddyfile` und `docs/deploy-prod.md` beschreiben denselben Routing- und Netzpfad konsistent.

- `[open]` Der Prod-Predeploy-Check für öffentliche URLs, TLS-Zwang und das Verbot von `localhost`/`http://` ist noch nicht automatisiert.
  Acceptance criteria: Ein Predeploy-Check schlägt fehl, wenn Prod-Configs `localhost`, `http://` oder leere `*_PUBLIC_BASE_URL` enthalten.

- `[open]` Provider-`/metrics` sind in der Referenz noch öffentlich erreichbar und nicht als privater Scrape-Pfad separiert.
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

## Data/Backups

- `[open]` Backup/Restore für die SQLite-Volumes ist dokumentiert, aber noch kein regelmäßig geübter, automatisierter Drill.
  Acceptance criteria: Ein Restore-Test aus gesicherten Catalog-, FAP- und Provider-Volumes bringt den Stack reproduzierbar wieder in einen grünen `healthz/readyz`-Zustand.

- `[open]` Es gibt noch keinen dokumentierten Datenintegritäts-Check nach Restore für ingest-, ledger- und asset-relevante Tabellen.
  Acceptance criteria: Nach einem Restore validiert ein Skript oder Runbook mindestens Asset-Metadaten, Provider-Announcements, `ingest_jobs` und FAP-Ledger-Daten gegen definierte Sollwerte.

- `[open]` Secret- und Key-Rotation ist für persistierte Daten nur teilweise beschrieben; insbesondere eine spätere `FAP_MASTER_KEY_HEX`-Rotation ist noch nicht operationalisiert.
  Acceptance criteria: Es existiert ein dokumentierter und testbarer Rotationspfad für Admin-Tokens, Webhook-Secrets und eine zukünftige Master-Key-Rotation ohne Datenverlust.
