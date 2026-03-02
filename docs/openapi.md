# OpenAPI Contracts

Each Go service serves its embedded contract directly:

- Catalog: `http://localhost:18080/openapi.json`, `http://localhost:18080/docs`
- FAP: `http://localhost:18081/openapi.json`, `http://localhost:18081/docs`
- Provider `eu_1`: `http://localhost:18082/openapi.json`, `http://localhost:18082/docs`

YAML remains embedded in-repo and available at `/openapi.yaml` for each service.

Canonical spec files live at:

- `services/audistro-fap/api/openapi.v1.yaml`
- `services/audistro-catalog/api/openapi.v1.yaml`
- `services/audistro-provider/api/openapi.v1.yaml`

## How To Update Specs

1. Change the handler/route.
2. Update the canonical `api/openapi.v1.yaml` spec in the same service.
3. Keep the embedded sync copy in that service aligned if it exists.
4. Run service tests and the OpenAPI gates.
5. If the change is intentional and breaking, review the `oasdiff` output before merging.

Safe contract changes:

- additive endpoints
- additive optional fields
- additive optional query parameters

Breaking contract changes:

- removing or renaming fields
- making an optional field required
- narrowing accepted enum values or parameter formats without a version bump

## Request Validation

Request validation is enforced in the HTTP stack using `kin-openapi` request validation.
It is applied to API routes and excludes health/docs/static routes.
Validation failures return the service's normal JSON error envelope.

## Gates

Local:

```bash
npm install
./scripts/openapi-lint.sh
BASE_REF=origin/main ./scripts/openapi-breaking.sh
```

Per-service contract coverage and request-validation tests remain part of the normal service suites:

```bash
cd services/audistro-fap && go test ./...
cd services/audistro-catalog && go test ./...
cd services/audistro-provider && go test ./...
```

CI:

- `openapi-lint` runs on every push and pull request.
- `openapi-breaking` runs only on pull requests against `main`.
- Router-to-spec coverage tests and request-validation tests live inside each service test suite.
- The smoke/unit matrix waits for `openapi-lint` before running.

Pinned tool versions:

- Spectral: `@stoplight/spectral-cli@6.15.0`
- oasdiff: `github.com/oasdiff/oasdiff@v1.11.10`
