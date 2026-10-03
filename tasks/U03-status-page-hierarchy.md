# U03 — Status page: make the section heading read as a heading, not a key

## Goal
Fix the visual ambiguity on the public status page where the `<h2>Network</h2>`
heading and the nested table rows share the same left alignment, so "Network"
reads like a label with a blank value instead of a section title.

## Context
On `_STATUS_HTML` the markup is `<h2>Network</h2>` followed by
`<table><tbody id="status-rows">…`. The `h2` and the row labels both sit flush
left with similar weight, so the hierarchy is not visually obvious — the user
read "Network" as a tree node whose child rows ("Network name (SSID)",
"Connected to") were values. This is purely presentational; the data is fine.

## Files touched
- `roles/travel-router/assets/status-server.py` — `_STATUS_HTML` `<style>` only
  (no markup/data change).

## Pre-conditions
- [ ] none. Touches the same block as U01 (rows) but a different region (CSS);
      either order works.

## Exact changes required

### Change 1: `status-server.py` — `_STATUS_HTML` `<style>` (currently ~lines 623-639)
Give the section heading a distinct treatment and indent the rows so they read
as children.

Before:
```css
  h1 { font-size: 1.25rem; }
  section { background: #1a2027; border-radius: 10px; padding: 0.9rem;
            margin-bottom: 0.9rem; }
  h2 { font-size: 1rem; margin: 0 0 0.5rem; }
  table { border-collapse: collapse; width: 100%; }
  td { padding: 2px 8px 2px 0; }
  .label { font-weight: 600; }
```
After:
```css
  h1 { font-size: 1.25rem; }
  section { background: #1a2027; border-radius: 10px; padding: 0.9rem;
            margin-bottom: 0.9rem; }
  h2 { font-size: 0.72rem; margin: 0 0 0.45rem; text-transform: uppercase;
       letter-spacing: 0.09em; color: #8b97a5; font-weight: 600;
       border-bottom: 1px solid #2a333d; padding-bottom: 0.35rem; }
  table { border-collapse: collapse; width: 100%; }
  td { padding: 3px 8px 3px 0; }
  .label { font-weight: 600; color: #c7cdd4; }
  #status-rows { border-left: 2px solid #2a333d; }
  #status-rows td { padding-left: 0.6rem; }
```

(Visual only. The uppercase muted heading + rule + left-indent rows make the
parent/child relationship unambiguous. The `.label` color bump keeps the row
labels readable under the new indentation.)

## Validation plan
```bash
# 1. Static: the new rules are present and the page still parses as the string.
python3 - <<'PY'
page = open("roles/travel-router/assets/status-server.py").read()
html = page.split('_STATUS_HTML = """')[1].split('"""')[0]
assert "text-transform: uppercase" in html, "heading rule missing"
assert "#status-rows { border-left" in html, "row indent missing"
assert "id=\"status-rows\"" in html, "container still present"
print("U03 static OK")
PY

# 2. Suite unchanged and green (no behavior asserts depend on the CSS).
bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -3
# Expected: SUITE GREEN

# 3. Visual (required for a UI change): screenshot the page and confirm the
#    heading is visually distinct from the rows. Load the skill `visual-qa`
#    and/or use Playwright against a local server bound to 127.0.0.1.
```

## Success criteria
- [ ] On the page, "Network" clearly reads as a section title, not a key.
- [ ] Row labels are indented under the heading.
- [ ] No data/markup/semantics change; suite green.
- [ ] Visual check confirms the hierarchy (screenshot evidence).

## Rollback
```bash
git checkout roles/travel-router/assets/status-server.py
```

## Next task
Update `tasks/PLAN.md` (Wave U index). Consider applying the same heading
treatment to the "Helpful Links" section for consistency (same page, same
`h2` rule, no extra work).
