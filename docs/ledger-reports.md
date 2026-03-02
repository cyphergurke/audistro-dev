# Ledger Reports

`GET /v1/ledger/reports` returns a device-scoped monthly batch derived from paid `ledger_entries`.

- Scope: one `fap_device_id` cookie only; there is no cross-device aggregation in v1.
- Periods: UTC month boundaries, inclusive start and exclusive end.
- Query: `month=YYYY-MM`; when omitted, FAP uses the current UTC month.
- Contents: totals plus per-payee and per-asset breakdowns sorted by amount descending.
- Recompute: if a new paid ledger entry appears in the same period after a report was computed, FAP marks the persisted row stale and recomputes it on the next request.
