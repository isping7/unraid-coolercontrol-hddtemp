# Architecture

## Module map

```
plugin/
├── cooler-hddtemp.page       orchestration + rendering + config domain
├── cooler-hddtemp-en.page    legacy English URL → meta redirect to ?lang=en
├── assets/
│   ├── cct.css               all styles (single theme, fixed palette)
│   └── cct.js                all interaction (polling, dirty state, drawer, export, i18n)
├── lib/
│   ├── scan.php              disk domain (CLI): smartctl scan + slot ordering → JSON
│   └── control.php           process domain (CLI): status / start / stop → JSON
├── scripts/
│   └── collector.sh          the collector itself (bash, one long-running process)
└── bin/
    └── selftest.sh           read-only and destructive self-tests
```

The page calls the CLI modules with `exec('php lib/scan.php')` and parses their JSON.
It deliberately **does not `require`** them: on emhttp, including another PHP file from a
`.page` makes the output get `<script>`-escaped, which silently breaks the page.

`assets/` is served by nginx directly from `/plugins/cooler-hddtemp/assets/…`, exactly like
`status.json`. That is why `/boot/config/go` must copy the `assets` directory into RAM as
well — otherwise the page loads without CSS/JS after a reboot.

## Data flow

```
User Scripts (At Startup of Array)
        │
        ▼
collector.sh  ── every round ──▶ smartctl -iA per drive
        │                        │
        │                        ├── aggregate (max|avg) per group
        │                        ├── write  /mnt/user/appdata/coolercontrol/hdd_temp   (millidegrees)
        │                        ├── write  /mnt/user/appdata/coolercontrol/ssd_temp
        │                        └── write  /usr/local/emhttp/plugins/cooler-hddtemp/status.json
        ▼
CoolerControl (1 s poll) ──▶ File custom sensor ──▶ fan curve ──▶ PWM
        ▲
WebUI polls status.json every N seconds and repaints the two panes
```

## Design decisions

### Saving never restarts the collector

`collector.sh` re-reads `settings.cfg` at the top of every round. A save therefore only has
to write the file; the next round (≤ interval) picks it up. This removes the 2–3 s data gap,
the PID churn and the double-instance window the old implementation had.

Consequence: the UI says "applies on the next round (≤ N s)", and the change lands one
round late.

### Config writes are atomic

`tmp` → `json_decode` validation → `rename`. Writing `settings.cfg` in place while the
collector reads it can hand Perl a truncated document; the measured result was a `0 drives`
round *and* `IV` falling back to its default of 30 s — i.e. the collector looked frozen for
half a minute. Atomic rename makes that impossible.

### Temperature files are written non-atomically on purpose

CoolerControl keeps the last good value and only enters fail-safe after
`MISSING_STATUS_THRESHOLD = 8` consecutive failures. A single short write is invisible.
The trade-off: if the collector dies, the file stays readable and the fans keep the last
PWM — CoolerControl cannot detect *stale* content. The UI surfaces that as a "stale" badge;
there is no watchdog by design.

### Single page + cookie i18n

Two `.page` files would double the PHP. A cookie (`cct_lang`) or `?lang=en` selects the
translation array inside one file; the old `cooler-hddtemp-en.page` is kept as a meta
redirect so old bookmarks still work.

### The stop button lives outside the UI

Stopping the collector is an infrastructure action (array shutdown) or a maintenance one,
not a day-to-day click. It is available as `php lib/control.php stop` and via a User
Scripts entry on `stopping_svcs`. The UI only offers *Start* when it detects the collector
is not running, which is the recovery path.

## emhttp constraints worth remembering

| Constraint | Consequence |
|---|---|
| `build_pages()` splits the header on the literal `\n---\n` | CRLF makes the page vanish from the menu; only `Invalid .page format` in syslog |
| `require` of another PHP file | output gets `<script>`-escaped |
| RAM pages must be created with `cp`, not a shell pipe | piped writes break the escaping rules |
| PHP CLI runs in UTC while emhttp runs in local time | timestamps must come from `shell_exec('date …')` |
| `pgrep -f` matches command-substitution children | count instances with `PPID=1` |
| bash reads scripts by byte offset | editing a running script in place may execute garbage — restart or replace by `mv` |
