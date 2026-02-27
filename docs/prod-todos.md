# Production TODOs

## Pflege-Regel (ab sofort)

- Bei jeder nicht-produktionsreifen Implementierung muss diese Datei im selben Change aktualisiert werden.
- Eintrag immer mit kurzer Begründung, Risiko und geplantem Exit (wie wird der Workaround entfernt?).
- Ziel: Kein dauerhaftes Dev-/Test-Hack-Verhalten ohne sichtbaren Prod-Plan.

## Kontext
Aktuell wird im Dev-Smoke ein Workaround genutzt:

- deterministic registry upsert from provider identities for dev HTTP setup (catalog announce path enforces HTTPS)

Das ist für lokale Tests ok, aber kein belastbarer Produktionspfad.

## P0 (Blocker vor Prod)

- [ ] Einheitliche Transport-Policy definieren und durchziehen (`https` end-to-end).
- [ ] Provider-Announce-Flow ohne DB-Bypass betreiben (kein direktes Upsert in `providers`/`provider_assets` außerhalb von Notfall-Tools).
- [ ] Dev/Stage so aufsetzen, dass der echte Signaturpfad gegen Catalog durchläuft (inkl. gültiger `https`-URLs).

### Akzeptanzkriterien P0

- [ ] `POST /v1/providers/{providerId}/announce` ist in Dev/Stage/Prod der einzige Pfad für Provider-Registrierung.
- [ ] Smoke-Test besteht ohne Registry-Upsert-Hack.
- [ ] Fallback-Test basiert auf echten Announcements und zeigt weiterhin: erster Provider fehlschlägt, nächster Provider liefert Segmente.

## P1 (Härtung)

- [ ] Lokale TLS-Strategie für Dev dokumentieren (z. B. Reverse-Proxy mit lokalen Zertifikaten).
- [ ] Klare Policy pro Environment dokumentieren:
  - Dev: welche Insecure-Ausnahmen erlaubt sind.
  - Stage/Prod: `https` zwingend, keine Ausnahmen.
- [ ] Alerting ergänzen für Announce-Fehlerquoten (`catalog bad request`, `unauthorized`, Signaturfehler).

## P2 (Betrieb)

- [ ] Runbook für "Provider announce fails" erstellen (Diagnose, Metriken, Logs, Recovery).
- [ ] CI-Gate hinzufügen: Build/Smoke schlägt fehl, wenn direkte Registry-Upserts im regulären Testpfad verwendet werden.

## Konkrete nächste Schritte

1. Einen echten `https`-fähigen Dev-Pfad einführen (Proxy + Zertifikate) und Smoke darauf umstellen.
2. Den aktuellen DB-Upsert im Smoke als temporären Fallback hinter explizitem Flag kapseln (default: aus).
3. Nach erfolgreicher TLS-Umstellung den Fallback-Code vollständig entfernen.
