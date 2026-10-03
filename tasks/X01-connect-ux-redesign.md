# X01 — Redesign: connect dialog becomes the credential hub

## Goal
Make the connect dialog the single place you connect to a network AND manage
its saved passwords; retire the standalone "Saved passwords" section; give
"Try saved passwords" real-time-feel progress. Keep the existing dark aesthetic
and the vanilla-JS/no-build constraints.

## Design decisions (owner-approved)
1. **Dialog is the hub.** Scan-row Connect and known-card Connect open it. The
   dialog carries an editable SSID (so hidden networks still work) + password +
   Connect + Try saved passwords + the saved-password list for that network.
2. **Consolidate the saved-passwords UI into the dialog.** Delete the standalone
   `#pskmanage-section`. Per-network candidates (add/remove) live in the dialog;
   global "defaults" (tried for any network) are a clearly-labeled secondary
   group in the same dialog.
3. **Cosmetic progress only.** No backend change: on "Try saved passwords", the
   already-returned per-candidate log lines are revealed sequentially (~350ms),
   each as a row with a spinner, ending in success/failure. Respect
   `prefers-reduced-motion` (reveal instantly).
4. **Keep the look.** Existing palette (#101418 bg, #1a2027 surfaces, #222a33
   cards, accent #2d7ff9, ok #5dd879, warn #ffb84d). No new accent, no new
   dependency, no framework. This is a focused redesign, not a re-theme.

## Constraints (hard — the suite pins these)
- **DOM rule:** createElement + textContent ONLY. Zero `innerHTML`,
  `outerHTML`, `insertAdjacentHTML`, `document.write` (suite asserts count==0).
- **Preserve ids/labels the suite pins** (unless X02 updates the assert):
  `net-dialog`, `Try saved passwords`, `Connect manually` (or update §5x if the
  section is removed), `escape-aware SSID splitter` marker, `admin-session`,
  `function mcWrite(`, `function sessionFetch`, `function handleAuth`,
  `PIN required — enter it in the PIN section`.
- **Preserve counts:** `X-Session` occurrences == 5; `"X-Session"` == 1;
  `"/api/wan/known"` == 2; `sessionFetch("/api/wan/known"` == 2;
  `fetch("/api/wan/known"` == 0. (If the redesign changes these, X02 updates the
  asserts in the same wave.)
- **`mcWrite` signature + `var body = extra || {}` + `busy(true)`** must survive
  (§5ae pins it).
- **AP-dialog strings** (`body.hidden = !hiddenChecked`, `doApSave({ pin: pin,
  hidden: desiredHidden })`, `id="ap-hidden-apply"`, `id="ap-hide-confirm"`) must
  survive unchanged — do not touch the AP-settings dialog.

## API (existing — no backend change)
- `POST /api/wan/psks-manage` `{pin, action, ...}` — actions: `"del"` `{n}`,
  `"add-default"` `{psk}`, `"add"` `{ssid, psk}` (per-network; supported but
  currently unused by the UI — expose it).
- `GET /api/wan/psks-manage` → `{rows:[{type,index,ssid}]}` (values never returned).
- `POST /api/wan/psks` `{ssid}` → `{ok, rc, lines:[], log:[...]}` (per-candidate
  lines live in `log`).
- `POST /api/wan/connect` `{ssid, psk?}`; `/api/wan/forget` `{ssid}`;
  `/api/wan/disconnect` `{}`; `POST /api/wan/scan`; `GET /api/wan/known`.
- Client helpers to reuse: `api()`, `sessionFetch()`, `cellRow()`, `badge()`,
  `dMsg()`, `setMsg()`, `busy()`, `currentPin()`, `handleErr()`,
  `openNetDialog()`, `netDlgBusy()`.

## Files touched
- `roles/travel-router/assets/admin.html` — the redesign.

## Exact changes (structure, agent latitude on visual details)

### 1. Retire the standalone section
Remove `<section id="pskmanage-section">` (markup + its `psksManage`/
`renderPskRows`/`refreshPskManage`/`pm-add`/`pm-refresh` JS), moving that
functionality into the dialog. Keep a Disconnect/Forget affordance (move to the
Network status section or per-known-card — implementer's call, but it must stay
reachable).

### 2. Rebuild `#net-dialog` as the hub
Structure (ids are suggestions; keep DOM-safe and accessible):
- `<h2>Connect to <ssid></h2>` — SSID shown in the title (editable text input so
  hidden networks work; prefill from the scan/known row, blank for manual).
- Password input + **Connect**.
- **Try saved passwords** — primary secondary action; on click reveals progress.
- Progress region: a list that appears during the try, one row per candidate
  ("Trying password 1 of N…", spinner) then a result row (connected / not
  found). Reveal the returned `log` lines at ~350ms intervals; reduced-motion
  reveals instantly. If no candidates, show a clear empty state.
- **Saved passwords** disclosure (collapsed by default):
  - "For this network" — rows from `GET psks-manage` filtered by SSID, each with
    Remove; plus an "Add a password for this network" field → `action:"add"`.
  - "Defaults (tried for any network)" — `d`-rows, each with Remove; add via
    `action:"add-default"`.

### 3. Route manual connect through the dialog
"Connect manually" becomes an entry point that opens the dialog (SSID editable),
OR is removed if the dialog's editable SSID fully covers it — implementer's
call, but the suite §5x asserts `Connect manually` exists; if removed, X02 must
update §5x. Prefer keeping a "Connect manually" button that opens the dialog
with an empty editable SSID.

### 4. Visual polish within the existing palette
- Consistent spacing scale; section labels get a subtle muted/uppercase
  treatment (matches the status page's U03 change for cross-page consistency).
- Buttons: clear primary/secondary/tertiary hierarchy (currently mostly
  filled+ghost), hover/active/focus-visible states, 200–300ms transitions on
  transform/opacity only.
- Empty, loading, and error states for the dialog; no `window.alert`.
- `font-variant-numeric: tabular-nums` on any row index / counts.
- Mobile-first (this is used from a phone on the travel AP); dialog max-width,
  scrollable body.

## Verification (must pass before "done")
1. `python3 -m py_compile` n/a (HTML); extract `<script>` and `node --check`.
2. DOM rule: no forbidden sinks (grep).
3. Suite green (X02 updates any deliberately-changed pinned strings/counts).
4. **Visual QA** — `/visual-qa` (or headless screenshots) at 375/768/1280,
   logged-in session, dialog open, progress state, saved-passwords expanded,
   reduced-motion pass.

## Rollback
```bash
git checkout roles/travel-router/assets/admin.html
```

## Next task
X02 (suite asserts + docs).

## X02 execution note (2026-10-03)
Added 9 §5x asserts (pskmanage-section removed; dialog-hub ids; `action:'add'`;
`revealTryLines`; reduced-motion guard; border-box) and documented the hub in
`roles/travel-router/README.md`. Suite GREEN **635/0** (was 626).

## Execution note (2026-10-03)
Executed directly (subagent delegation was unavailable — no tokens for the
visual-engineering model). Implemented in `admin.html` only:
- Removed the standalone `#pskmanage-section`; its add/remove capability moved
  into `#net-dialog` as a collapsed "Saved passwords" `<details>` with
  "For this network" (`action:"add"` — the endpoint already existed) and
  "Defaults (tried for any network)" (`action:"add-default"`).
- Dialog is now the hub: `<h2 id="d-title">Connect to <ssid></h2>` + an editable
  SSID input (`#d-ssid-input`; supports hidden networks) + password + Connect +
  Try saved passwords. `openNetDialog()` seeds it; typing updates `DIALOG_SSID`.
- "Try saved passwords" reveals the per-candidate `log` lines via
  `revealTryLines()` (~350ms; `prefers-reduced-motion` → instant) as `.prow`
  rows with a spinner, green on OK / amber on failure.
- `mc-connect` now opens the dialog (SSID prefilled) instead of a direct call.
- Visual polish: border-box dialog sizing (fixed a real box-model overflow since
  `<dialog>` defaults to content-box), wrapped action row, hover/active/
  focus-visible states, reduced-motion guard, tabular-nums on row labels.

Validation: `node --check` on the script block OK; 0 forbidden DOM sinks; every
pinned substring/count preserved (X-Session==5, quoted==1, known-fetch==2/2/0);
no dangling refs to removed ids/functions; suite GREEN **626/0** (×2).
Visual QA: headless-Chrome harness rendering the real `admin.html` at 500/768/
1280px — dialog caps at 26rem and centers; content wraps, no clipping.
(Caveat: headless Chrome enforces a 500px minimum window, so true 375px could
not be captured; the box-sizing fix makes it correct there regardless.)

## Deferred/related
- `tasks/PLAN-ssid-common.md` (SC-wave, owner's) is deferred; its uncommitted
  code was stashed as `stash@{0}` before X01 started, so X01 sits on a clean base.
