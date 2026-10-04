# Project Plan — Common-SSID pool via `.ssid_common` (SC-wave)

Last updated: 2026-10-03
Status: IMPLEMENTATION COMPLETE (SC01–SC06) — rebased onto the X01 base;
SQ (hardware QA) is USER-GATED.

Feature: an optional, gitignored repo-root file `.ssid_common` (one SSID per
line, `#` comments / blank lines skipped — same contract as `.psksecret`)
feeds a **common-SSID pool** on the router. The AP-settings "Random name"
button (and the `ssid == "random"` curl path) then draws from the pool when
it is non-empty, instead of always minting from the no-lookalike alphabet.
The admin page also gets a chooser: a session-gated endpoint lists the pool,
and "use this one" fills the SSID field — so a new travel SSID can be picked
deliberately from your common list or drawn at random from it.

## Review findings (what exists today)

1. **The `.psksecret` pipeline is the template and it is complete
   end-to-end.** Both provisioners stage a repo-root seed file next to
   `role.env` (`provision.sh:209-214`, `provision-bookworm.sh:168-173`),
   `install.sh` loads it via the same two-path idiom as ROLE_ENV with
   env override (`TRAVELROUTER_PSKSECRET_FILE`, install.sh:244-253),
   validates + merges + stages a 0600 provenance copy (install.sh:253-312),
   the QA battery has a dedicated section (validate-local.sh 5v), and
   `.gitignore` carries the entry. `.ssid_common` reuses every one of
   these idioms with a new name.
2. **The runtime random-SSID mint already exists in exactly one place:**
   `status-server.py:_random_ap_ssid()` (line ~1015): 8 chars over the
   no-lookalike alphabet via `secrets.choice`. Both surfaces route through
   it — the phone "Random name" button via `POST /api/admin/apconfig/preview`
   (line ~1212) and the apply path's `ssid == "random"` expansion (line
   ~1274). Intercepting this one function gives both surfaces pool support
   for free — no new mint site.
3. **The AP's live SSID is owned by runtime state, not role.env:** every
   ap-apply writes `/etc/rpi-project/travel-router/ap-ssid` and re-renders
   hostapd from that file + role.env (travel-wan.sh ap-apply:~654-677). So
   a pool pick needs NO new render field, NO template change, and survives
   re-provision the same way a manual rename does (re-provision resets to
   `.env` values by design).
4. **Gap:** nothing feeds a curated SSID list to the router today, and the
   preview response carries no indicator of where the SSID came from.
5. **Apply-path semantics are already correct and untouched:** identity
   change rotates the session salt; no-op rename doesn't; failed apply
   restores the old config (parse-probe + rollback). Pool picks land in the
   existing validation funnel (`_ssid_valid`, ≤32 bytes) before the
   probe — a pool entry that violates the SSID policy exists only at
   install time, where it fails loudly (below).

## Design decisions

1. **File contract mirrors `.psksecret` 1:1.** Optional repo-root
   `.ssid_common`; one SSID per line; `#` comments + blank lines skipped;
   trimmed of surrounding whitespace. Both provisioners stage it next to
   role.env when `ROLE=travel-router`. `.gitignore` gains `.ssid_common`.
2. **install.sh ingest → `/etc/rpi-project/travel-router/ssid-common`
   (0600 root).** Load via `TRAVELROUTER_SSID_COMMON_FILE` env override,
   else the role-tree two-path idiom (`${ROLE_ENV%/*}/.ssid_common`,
   `/boot/firmware/role/.ssid_common`, `/boot/role/.ssid_common`).
   Validation: printable ASCII (same `$PRINTABLE_RE`), ≤32 bytes, no
   TAB/CR/LF — any bad entry fails install with a remediation message
   (same fail-loud posture as psksecret TAB/CR/LF), so a malformed pool
   never ships. Dedupe keeps first occurrence. Absent file → no pool file
   → runtime behavior is byte-identical to today (zero-change default).
   A staged 0600 provenance copy (`kpsksecret`-style) is optional and NOT
   carried in v1 — an SSID list is not a credential; skip the extra file.
3. **Randomness owner stays `status-server.py` and stays one function.**
   `_random_ap_ssid()` reads the pool file on each call (it's tiny; no
   caching, no mtime games), validates nothing (already validated at
   install) and picks one entry with `secrets.choice`; empty/missing pool
   → the existing no-lookalike alphabet (today's behavior). The preview
   response gains `"source": "pool"|"generated"` — additive JSON, existing
   clients ignore it.
4. **Explicit choosing gets its own session-gated read,
   `GET /api/admin/ssids-common`:** JSON list of pool entries (read-only,
   no PIN — reads are read-only posture in this admin page; the write gate
   is the existing apconfig apply). The AP-settings card renders the pool
   as buttons/"use this one" rows that only FILL the SSID field; the save
   still goes through the normal PIN-gated `/api/wan/apconfig` — the
   chooser creates no second write path. Empty pool → the section renders
   a "(no common SSID list provisioned)" note.
5. **No `travel-wan` CLI verb in v1.** The pool file is a static seed;
   editing it means staging the file + re-running the ingest (documented),
   which the dry-run battery covers. A runtime editor is a later wave if
   wanted.
6. **README + `.env.example`:** document `.ssid_common` next to the
   `.psksecret` section and note in the AP-settings section that "Random
   name" prefers the pool when provisioned.

## Task list

- [x] SC01 — Provisioners stage `.ssid_common` next to role.env
      (provision.sh + provision-bookworm.sh) + `.gitignore` entry
- [x] SC02 — install.sh: load/validate/dedupe `.ssid_common` →
      `ssid-common` (0600) + banner line
- [x] SC03 — status-server.py: pool-aware `_random_ap_ssid()` +
      `"source"` field in preview + `GET /api/admin/ssids-common`
- [x] SC04 — admin.html: AP-settings pool chooser (fill-only) +
      source hint on preview
- [x] SC05 — validate-local.sh: 5x battery for SC01/SC02 (stage, 0600,
      dedupe, fail on bad bytes, absent-file skip, gitignore)
- [x] SC06 — README + `.env.example` docs
- [ ] SQ  — Hardware QA (USER-GATED: flash with a populated
      `.ssid_common`, confirm preview draws pool entries, apply a pool
      pick, confirm ap-ssid file + session rotation; confirm empty-pool
      default unchanged)

## Review + rebase note (2026-10-03)

Implementation reviewed against the stashed branch and rebased onto the X01
base (which had rewritten `admin.html`). Two copy/paste artifacts found in the
original branch and fixed: a duplicated, unreachable `/admin` route branch in
`status-server.py` (D1) and a duplicated `ap-random-psk` click listener in
`admin.html` that double-fired the preview POST (D2). §5sc gained three
uniqueness guards so this class of defect is caught structurally. The original
branch also predated X01; the pool chooser and the X01 connect hub now coexist
(the pool chooser lives in the AP-settings card, untouched by X01).
Suite: 656 passed, 0 failed (with the uniqueness guards).

Order: SC01 → SC02 → SC03 → SC04 → SC05 → SC06 → SQ. One commit per task
(`feat(provision):` / `feat(travel-router):` / `test:` / `docs:`).

## Validation gate

`bash roles/travel-router/assets/validate-local.sh` — must stay green
after every task; SC05 extends it (suite is long, minutes: run before
starting to have a baseline). Server behavior (SC03) is not reachable from
the dry-run battery — the pool-aware mint is proven on hardware in SQ
(curl the preview endpoint repeatedly against a seeded pool).

## Blocked

None.