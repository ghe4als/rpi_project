# t5 — Shift NATS broker IP 192.168.0.76 -> 192.168.0.151

## Status
- **COMPLETED** — commit `ff4f76e` (2026-09-13).

## What was done
Replace every `192.168.0.76` with `192.168.0.151` across env examples, README
(with the Netdata / Netdata-broker lines), base role `NATS_URL` defaults, and
docs.

## Notes
- `.env` (gitignored, local secrets) also contains 2 occurrences — **not**
  covered by this commit; left for a local edit intentionally.

[END]
