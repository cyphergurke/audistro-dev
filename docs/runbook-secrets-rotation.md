# Runbook: Secrets Rotation

This runbook covers operationally realistic rotations for the current stack.

The source of truth for unfinished production work stays in [`docs/prod-todos.md`](./prod-todos.md).

## Inventory

Track at minimum:
- `FAP_WEBHOOK_SECRET`
- `FAP_ADMIN_TOKEN`
- `CATALOG_ADMIN_TOKEN` for controlled dev/admin environments
- provider internal/admin tokens if introduced operationally
- `origin_hmac_secret`
- `fap_token_secret`
- `FAP_MASTER_KEY_HEX`
- LNbits payer/admin keys used in smoke or operations

For every secret record:
- owner
- last rotation time
- dependent services
- rollback contact

## Low-Risk Rotations

### FAP webhook secret

Blast radius:
- incoming settlement webhooks fail until the sender and FAP agree on the new secret

Procedure:
1. Generate the new secret.
2. Update the sender or webhook source to support the new secret.
3. Update `FAP_WEBHOOK_SECRET` in deployment config.
4. Restart FAP.
5. Trigger a staging or controlled webhook and confirm `204`/success.
6. Remove the old sender secret.

Rollback:
- restore the previous `FAP_WEBHOOK_SECRET` and replay the webhook if possible.

Acceptance check:
- a post-rotation webhook succeeds and no unexpected 401/403 spikes appear.

### Admin tokens

Blast radius:
- internal packaging-key calls, dev admin proxies, or controlled operational endpoints fail until all callers use the new token

Procedure:
1. Generate the new token.
2. Update the calling systems first where overlap is possible.
3. Update the target service env.
4. Restart the service.
5. Verify the protected endpoint with the new token.
6. Remove the old token from callers and secret stores.

Rollback:
- revert the token in the service env and callers to the last known good value.

Acceptance check:
- the protected endpoint succeeds with the new token and fails with the retired token.

### Token and HMAC secret files

Blast radius:
- token verification and provider origin validation fail if rotations are not coordinated

Procedure:
1. Write the new file under a staged path.
2. Update deployment manifests to point to the new path or replace the mounted secret atomically.
3. Restart the affected service.
4. Run the relevant smoke or origin verification check.

Rollback:
- restore the previous secret file and restart the affected service.

Acceptance check:
- token or origin-auth checks succeed after restart and error rates remain flat.

## Future Rotation: `FAP_MASTER_KEY_HEX`

Current state:
- in-place rotation is not implemented
- existing encrypted data depends on the current master key

Operational stance:
- treat master-key rotation as a planned migration project, not an emergency flip

Planned future shape:
1. introduce explicit key versioning for encrypted rows
2. allow dual-read / single-write during migration
3. re-encrypt stored secrets under the new key
4. cut writes to the old key
5. remove the old key only after a verified migration window

Rollback concept:
- maintain the previous key until re-encryption and verification are complete

## Post-Rotation Checklist

- smoke the affected path
- update the secret inventory timestamp
- close any temporary overlap window
- remove superseded secrets from CI, deploy automation, and operator machines
