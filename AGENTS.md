# Local Editing Protocol — pi (for this repo)

Companion to the global agent rules. These are the concrete, hands-on rules
that actually stop edit retries from burning context.

## Byte-accurate reads before edits (highest value)

Read tools can misrepresent bytes: they may hide whitespace or show content
that visually matches but does not match the on-disk bytes. This is the single
biggest source of failed edits → retries → wasted context.

- When you need to edit an existing file, **trust the shell bytes over the
  Read UI.** Confirm the exact target bytes with `od` before editing:

  ```bash
  sed -n '82,95p' roles/travel-router/install.sh | od -c
  ```

- Use the **Edit tool** (string match) as the first choice — it is
  self-locating and fails loudly rather than silently corrupting.
- Copy the `old_string` from the most recent read; if whitespace is in doubt,
  Read it again or confirm with `od` — one extra tool call beats a failed edit.
- If the Edit tool fails twice, **stop** — report the exact `old_string`, the
  Read output, and the measured difference; do not keep retrying.

## Environment / shell quirks (this repo)

- Default shell is GNU bash 5.3.15 at `/opt/homebrew/bin/bash`.
- In a dry-run, `env -i` drops the **right-most** inline assignment even when
  exported, so pass important variables non-last or export them explicitly.

---

Global agent rules (identity, weak-model mode, planning, execution discipline)
are provided by the harness. Local repo-specific editing rules live here.
