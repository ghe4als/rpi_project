// mobile-folder-upload.js — re-enable copyparty's folder picker on touch devices
//
// Upstream up2k.js skips the "Files / One folder?" dialog on mobile:
//     // phones dont support folder upload
//     if (MOBILE)
//         return uf();
// Android browsers (Chrome 132+, Firefox 142+) DO support the
// <input webkitdirectory> picket that "One folder" uses, so on those this
// shim rebinds the upload button to restore the dialog. Older engines keep
// the files-only picker via the same Chrome<=72 guard upstream applies.
//
// Loaded via `--js-browser /.res/mfu.js` (URL inside the shared volume at
// /var/lib/copyparty/.res/mfu.js). Runs after up2k.js; `ebi`, `modal` and
// `L` are globals from util.js/browser.js. Upstream `uf`/`ud` are closure
// locals, so we replicate them against the live DOM: the file/dir inputs
// are regenerated as `file{N}`/`dir{N}` (up2k.js more_one_file()), and N
// is derived at click time so form regeneration cannot break the binding.
"use strict";

(function () {
    var TAG = "[mfu]";

    function log(msg) {
        if (window.console && console.log)
            console.log(TAG + " " + msg);
    }

    // last generated input set: highest N among file{N} inputs
    function latest_ctr() {
        var best = -1, inputs = document.querySelectorAll('input[id^="file"]');
        for (var a = 0; a < inputs.length; a++) {
            var m = /^file(\d+)$/.exec(inputs[a].id);
            if (m) {
                var n = parseInt(m[1], 10);
                if (n > best) best = n;
            }
        }
        return best;
    }

    function uf() {
        var n = latest_ctr();
        if (n < 0) return log("no file input found");
        var elm = ebi("file" + n);
        if (elm) elm.click();
        else log("file" + n + " vanished");
    }

    function ud() {
        var n = latest_ctr();
        if (n < 0) return log("no file input found");
        var elm = ebi("dir" + n);
        if (elm) elm.click();
        else log("dir" + n + " vanished");
    }

    function nav() {
        if (typeof start_actx === "function")
            start_actx();

        // same guard as upstream: webkitdirectory buggy on chrome <= 72
        var m = / Chrome\/([0-9]+)\./.exec(UA);
        if (m && parseInt(m[1], 10) < 73)
            return uf();

        // dialog text/buttons reuse the upstream translations verbatim;
        // L is re-read at click time (language switch reassigns the global)
        var txt = (L && L.u_nav_m) ||
            '<h6>aight, what do you have?</h6><code>Enter</code> = Files (one or more)\n<code>ESC</code> = One folder (including subfolders)';
        var buttons = (L && L.u_nav_b) ||
            '<a href="#" id="modal-ok">Files</a><a href="#" id="modal-ng">One folder</a>';

        modal.confirm(txt, uf, ud, null, buttons);
    }

    function bind() {
        var btn = ebi("u2btn");
        if (!btn) return false;
        btn.onclick = nav;
        return true;
    }

    function init() {
        if (typeof MOBILE === "undefined" || !MOBILE)
            return log("not a touch device; shim idle"); // desktop: upstream dialog already works

        if (!bind()) {
            log("u2btn missing; retrying after DOM settle");
            setTimeout(init, 1000);
            return;
        }

        // up2k.js may hide/reshow or re-render the button container
        // (style.display toggles), but onclick survives those; a periodic
        // re-arm guards against full re-render without observers.
        setInterval(function () {
            if (ebi("u2btn") && ebi("u2btn").onclick !== nav)
                bind();
        }, 5000);

        log("folder-picker enabled on mobile (webkitdirectory OK in this engine)");
    }

    if (document.readyState === "loading")
        document.addEventListener("DOMContentLoaded", init);
    else
        init();
})();