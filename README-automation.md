# AVD Patching — Automated & Scheduled (how it works and how to set it up)

This repo now runs the **entire** AVD golden-image patch cycle automatically, on a
schedule, with no human clicking anything. This file explains what changed, how to
turn it on, and the two follow-up settings you should configure in Azure DevOps.

---

## 1. What runs now

A single new pipeline — **`pipelines/avd-patching-scheduled.yml`** — runs all the
phases in order and passes the values between them automatically:

| Stage | Runs | Notes |
|-------|------|-------|
| 1. Validate | `scripts/00-validate-environment.ps1` | Guard (third-Saturday check) + generates the image version + pre-flight checks. Fails fast if anything is wrong. |
| 2. Create golden VM | `scripts/01-create-golden-vm.ps1` | Publishes the golden VM name for the next stage. |
| 3. Patch, Sysprep, Capture | `scripts/02` + `scripts/03` | Uses the golden VM name and the generated image version. |
| 4. Deploy new hosts + drain old | `scripts/04` + `scripts/05` | Uses the image version. Old hosts are drained only if the new ones deployed. |
| 5. On failure | `scripts/07` + `scripts/08` | Runs **only** if a stage failed: removes the orphaned golden VM and sends an alert. |

The **daily cleanup** of drained hosts stays exactly as it was —
`pipelines/phase-4-cleanup-old-hosts.yml` on its own daily 02:00 schedule.

Nothing about *how* patching works was changed — only how the phases are
orchestrated and started.

---

## 2. The schedule (third Saturday, 22:00 IST)

```
schedules:
- cron: "30 16 * * 6"     # every Saturday 16:30 UTC = 22:00 IST Saturday
  always: true
```

Azure DevOps runs cron in **UTC**, and its cron **cannot** say "third Saturday"
directly. So the pipeline fires **every** Saturday at 16:30 UTC (22:00 IST) and the
first step — the **guard** — only lets the run continue when the date is between the
15th and the 21st, which is *always* the third Saturday. On the other Saturdays the
run starts, sees it's not the third Saturday, and stops immediately without doing
anything.

> To change the time: pick your IST time, subtract 5:30 to get UTC, and update the
> `30 16` (minute hour) part. To change to a different "nth" weekday, adjust the day
> range in the guard step (1st = 1–7, 2nd = 8–14, 3rd = 15–21, 4th = 22–28).

---

## 3. Key Vault name — now only from config

The Key Vault name is read **only** from `config/avd-prod-weu.json` → `KeyVaultName`.
The old hard-coded `kv-avd-prod-weu` value in phase-2 has been removed. There is now
exactly one place to change the vault name.

---

## 4. How to turn it on (one-time, in Azure DevOps)

1. Push this repo (all changes are on your feature branch → merge to `main` after review).
2. In Azure DevOps → **Pipelines → New pipeline → Azure Repos Git → your repo →
   Existing Azure Pipelines YAML file** → choose `/pipelines/avd-patching-scheduled.yml`.
3. Save it (you do **not** need to run it — the schedule will start it).
4. Confirm the schedule is picked up: open the pipeline → **⋮ → Scheduled runs**.

> Test tip: to prove it end-to-end without waiting for the third Saturday, run it
> manually once (**Run pipeline**) against a **non-production** host pool. When run
> manually the guard still checks the date — temporarily widen the guard's day range
> (e.g. `-ge 1 -and -le 31`) for the test, then set it back.

---

## 5. Failure alerts — set this up (recommended)

Because the run is unattended, you want to hear about a failure immediately. There
are two layers:

**A. Built-in Azure DevOps notification (recommended — no SMTP needed):**
1. Azure DevOps → **Project settings → Notifications → New subscription**.
2. Template: **"A build fails"** (or "A run stage fails").
3. Filter it to this pipeline, deliver to **you** (your email).
4. Save. You'll now get an email whenever a run fails — zero infrastructure.

**B. The in-pipeline email step (optional):** the failure stage also runs
`scripts/08-notify-failure.ps1`. It only sends mail if you set `SmtpServer` (and
optionally `NotifyFrom`) in the config. If `SmtpServer` is blank it does nothing and
does **not** fail the run — so option A above is the reliable default.

`NotifyEmail` in the config is already set to your address.

---

## 6. Retiring the old manual pipelines

Phases 1–3 (`phase-1-*`, `phase-2-*`, `phase-3-*`) are now marked **DEPRECATED** in a
banner comment at the top of each file. They still work as a manual fallback. **Once
the scheduled pipeline has completed a clean run in non-production**, delete those
three files (keep `phase-4-cleanup-old-hosts.yml`). The automated pipeline replaces
them.

---

## 7. Pre-go-live checklist

- [ ] Run `avd-patching-scheduled.yml` manually once against a **non-prod** host pool.
- [ ] Confirm each stage passes and values flow automatically (no manual input).
- [ ] Confirm the new image version appears in the gallery and new hosts register.
- [ ] Confirm old hosts go into drain mode.
- [ ] Set up the built-in failure notification (Section 5A).
- [ ] Point the config at production and merge to `main`.
- [ ] Delete the deprecated phase-1/2/3 pipelines (Section 6).
