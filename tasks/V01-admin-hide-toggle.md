# V01 — Admin: hide/show the AP on the fly (dedicated apply + confirm)

## Goal
Add a standalone "Apply hide/show now" control to the AP-settings card that
toggles SSID broadcast WITHOUT changing the SSID or password, with a
confirmation step. The backend already supports it; only the frontend blocks it.

## Context
`/api/wan/apconfig` already accepts a hidden-only body (`{pin, hidden}` with no
ssid/psk) and builds `ap-apply "" "" "2"|"0"`; `travel-wan.sh ap-apply` fills
the empty SSID/PSK from the live state and renders/restarts/rolls back exactly
as for a rename. Session self-destruct already fires when `hidden` differs from
live. **The only blocker is `admin.html`:** the Save handler returns early on
`if (!body.ssid && !body.psk)` (≈ line 931), so a hidden-only change can never be
submitted.

Owner decisions: a **dedicated apply button** (not the rename Save) and a
**confirm dialog**. Hiding restarts the radio, drops all clients, and rotates
the admin session (you must log in again and re-add the hidden network).

## Files touched
- `roles/travel-router/assets/admin.html` — button, confirm dialog, handlers,
  `busy()` list, loaded-state tracking.

## Pre-conditions
- [ ] U01–U03 committed (a20de7c). Independent otherwise.

## Exact changes required

### Change 1: add the button next to the broadcast checkbox
In the AP-settings section, replace the checkbox `<p>` (currently ~lines
259-267, the block containing both the `ap-hidden` label and the
`ap-hidden-warn` paragraph) — keep the label + warn paragraph, add the button
after the label and before the warn paragraph:

```html
    <p>
      <label for="ap-hidden">
        <input id="ap-hidden" type="checkbox">
        Broadcast this SSID (uncheck to hide)
      </label>
      <button id="ap-hidden-apply" type="button" class="secondary" disabled>Apply hide/show now</button>
    </p>
    <p class="dmsg" id="ap-hidden-warn" style="display:none">
      Hiding stops the beacon — after the AP restarts, re-add the network manually; hidden networks never appear in scans.
    </p>
```

### Change 2: add a dedicated confirm dialog
Insert after the existing `#ap-confirm` dialog block (~line 280, before
`<dialog id="net-dialog">`):

```html
<dialog id="ap-hide-confirm">
  <h2 id="ap-hide-title">Hide network?</h2>
  <p id="ap-hide-confirm-text"></p>
  <p>
    <button id="ap-hide-confirm-save" type="button">Yes, apply</button>
    <button id="ap-hide-confirm-cancel" type="button" class="secondary">Cancel</button>
  </p>
  <p class="dmsg" id="ap-hide-confirm-msg"></p>
</dialog>
```

### Change 3: track the loaded hide-state + enable the button only on change
Add a module-level `var AP_HIDDEN_LOADED = false;` near the other AP-settings
state (~ around the `refreshApInfo` area). In `refreshApInfo()` where it does
`document.getElementById("ap-hidden").checked = !d.hidden;`, also record the
loaded hide-state and refresh the button:

Before:
```js
      document.getElementById("ap-hidden").checked = !d.hidden;
      document.getElementById("ap-hidden-warn").style.display =
        d.hidden ? "" : "none";
```
After:
```js
      document.getElementById("ap-hidden").checked = !d.hidden;
      AP_HIDDEN_LOADED = !!d.hidden;
      document.getElementById("ap-hidden-warn").style.display =
        d.hidden ? "" : "none";
      updateHiddenApplyBtn();
```

Add the helper (near `apMsg`):
```js
function updateHiddenApplyBtn() {
  var desiredHidden = !document.getElementById("ap-hidden").checked;
  document.getElementById("ap-hidden-apply").disabled =
    (desiredHidden === AP_HIDDEN_LOADED);
}
```

Extend the existing checkbox `change` listener so it also refreshes the button:
Before:
```js
document.getElementById("ap-hidden").addEventListener("change", function () {
  document.getElementById("ap-hidden-warn").style.display =
    this.checked ? "none" : "";
});
```
After:
```js
document.getElementById("ap-hidden").addEventListener("change", function () {
  document.getElementById("ap-hidden-warn").style.display =
    this.checked ? "none" : "";
  updateHiddenApplyBtn();
});
```

### Change 4: the apply + confirm handlers
Add after the existing `#ap-confirm-save` handler (~line 972):

```js
document.getElementById("ap-hidden-apply").addEventListener("click", function () {
  var desiredHidden = !document.getElementById("ap-hidden").checked;
  if (desiredHidden === AP_HIDDEN_LOADED) { return; }
  var text = document.getElementById("ap-hide-confirm-text");
  while (text.firstChild) { text.removeChild(text.firstChild); }
  text.textContent = desiredHidden
    ? "Hiding stops broadcasting the SSID. All connected devices drop and must re-add the network manually. Your admin session also ends — you will need to log in again."
    : "Showing resumes broadcasting the SSID. All connected devices drop and must rejoin.";
  setMsg("ap-hide-confirm-msg", "");
  document.getElementById("ap-hide-confirm").showModal();
});

document.getElementById("ap-hide-confirm-cancel").addEventListener("click", function () {
  document.getElementById("ap-hide-confirm").close();
});

document.getElementById("ap-hide-confirm-save").addEventListener("click", function () {
  var pin = currentPin();
  if (!pin) {
    setMsg("ap-hide-confirm-msg", "PIN required — enter it in the PIN section", "warn");
    return;
  }
  var desiredHidden = !document.getElementById("ap-hidden").checked;
  document.getElementById("ap-hide-confirm").close();
  doApSave({ pin: pin, hidden: desiredHidden });
});
```

(`doApSave` is reused unchanged: for a hidden-only body `finalSsid` is empty, so
no `admin-last-ssid` write, and the post-restart poll reports "AP reconfigured".
The `hidden` value is already HIDE-semantics, matching the API contract — no
inversion here, unlike the broadcast checkbox.)

### Change 5: include the new button in `busy()`
In `busy(on)`'s id list (~line 1026), add `"ap-hidden-apply"`:
```js
  ["ap-save", "ap-hidden-apply", "ap-random", "ap-random-psk", "pm-add", "pm-refresh",
```

## Validation plan
```bash
# Static: new ids + hidden-only post present; suite static asserts (V02) will lock these.
grep -qF 'id="ap-hidden-apply"' roles/travel-router/assets/admin.html && echo "button OK"
grep -qF 'id="ap-hide-confirm"' roles/travel-router/assets/admin.html && echo "dialog OK"
grep -qF 'doApSave({ pin: pin, hidden: desiredHidden })' roles/travel-router/assets/admin.html && echo "hidden-only post OK"
grep -qF 'no innerHTML' roles/travel-router/assets/admin.html  # ensure DOM rule still holds
python3 - <<'PY'
page = open("roles/travel-router/assets/admin.html").read()
forbidden = ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write")
assert not any(f in page for f in forbidden), "DOM sink introduced"
print("DOM rule OK")
PY
bash roles/travel-router/assets/validate-local.sh 2>&1 | tail -3
# Expected: SUITE GREEN
```

## Success criteria
- [ ] "Apply hide/show now" is enabled only when the checkbox differs from loaded state.
- [ ] Clicking it opens a confirm dialog with hide/show-specific consequences.
- [ ] Confirming posts `{pin, hidden}` (no ssid/psk) to `/api/wan/apconfig`.
- [ ] No `innerHTML`/`document.write` introduced; suite green.

## Rollback
```bash
git checkout roles/travel-router/assets/admin.html
```

## Next task
V02
