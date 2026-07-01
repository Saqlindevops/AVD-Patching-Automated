# CHANGES — automation & scheduling

Summary of every change made to turn the manual four-pipeline process into one
scheduled, unattended run. Patching logic itself was **not** changed.

## Added

| File | Purpose |
|------|---------|
| `pipelines/avd-patching-scheduled.yml` | **The main change.** One scheduled pipeline that runs Validate → Create → Patch/Capture → Deploy/Drain, passing the golden VM name and the image version between stages automatically. Includes the third-Saturday guard and an on-failure stage. |
| `scripts/00-validate-environment.ps1` | Pre-flight checks: required config fields, Key Vault reachable, source image exists, subnet exists, host pool exists. Fails fast before any resource is built. |
| `scripts/07-cleanup-failed-run.ps1` | Runs only on failure. Removes the temporary golden VM (and its NIC/disks) if a run failed after it was created, so nothing is left running. |
| `scripts/08-notify-failure.ps1` | Best-effort failure email (needs `SmtpServer` in config). See README section 5 for the recommended built-in notification instead. |
| `README-automation.md` | Setup guide, schedule explanation, failure-alert setup, retirement steps, go-live checklist. |

## Modified

| File | Change | Why |
|------|--------|-----|
| `config/avd-prod-weu.json` | Added `NotifyEmail`, `NotifyFrom`, `SmtpServer`. | Supports the failure-alert step; keeps settings in config. |
| `pipelines/phase-2-patch-sysprep-capture.yml` | **Removed the hard-coded `keyVaultName: 'kv-avd-prod-weu'`.** Added a DEPRECATED banner. | Your explicit ask — the vault name now comes only from config. Phase 2 never used Key Vault anyway. |
| `pipelines/phase-1-create-golden-vm.yml` | Added a DEPRECATED banner. | Superseded by the scheduled pipeline; kept as manual fallback. |
| `pipelines/phase-3-deploy-new-hosts-drain-old.yml` | Added a DEPRECATED banner. | Superseded by the scheduled pipeline; kept as manual fallback. |

## Unchanged (intentionally)

- All patching logic in scripts `01`–`06`.
- `pipelines/phase-4-cleanup-old-hosts.yml` (keeps its daily 02:00 schedule).
- The blue/green host-index approach, drain process, and session-safety checks.

## How the values flow (no more manual input)

- **Image version:** generated once in Stage 1 (`init` step) as `YYYY.MMdd.HHmm`
  (e.g. `2026.719.2200`) and read by Stage 3 (capture) and Stage 4 (deploy).
- **Golden VM name:** produced by Stage 2's `createGolden` step (already emitted as an
  output variable) and read by Stage 3 via
  `stageDependencies.CreateGolden.CreateVM.outputs['createGolden.GoldenVmName']`.
- **Guard:** Stage 1's `guard` step sets `proceed=true/false`; every later stage has a
  `condition` that checks it, so non-third-Saturday runs stop cleanly.
