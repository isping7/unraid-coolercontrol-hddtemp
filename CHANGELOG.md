# Changelog

All notable changes to this plugin are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versioning is
`MAJOR.MINOR.PATCH` and the Unraid plugin version uses `YYYY.MM.DD` in `unraid/*.plg`.

## [3.1.0] — 2026-11-17

### Added
- **Auto-add new drives** (uto in settings.cfg, toggle in the settings drawer):
  every 60 s the collector runs smartctl over all devices, and adopts drives that are
  present but missing from the saved list — HDD/SSD classification comes from smartctl
  (Solid State Device), SAS drives count as HDD. Removed drives are dropped from the
  list at the same time.
- New CLI module lib/autoadd.php (pure logic, atomic config write, no-op when disabled).
- Ideal after replacing a disk: no manual re-selection, no CoolerControl change.

### Notes
- Enabling it **overrides manual exclusions** — a drive you unticked will be re-added.
  That is why the default is off.
## [3.0.0] — 2026-11-17

Complete rewrite of the WebUI and the data path. Settings are backward compatible.

### Added
- **Split architecture**: `.page` only orchestrates; disk scanning (`lib/scan.php`) and
  process control (`lib/control.php`) are CLI modules; CSS/JS live in `assets/`.
- **Single-page i18n**: 中文 / English switch through a cookie (`cct_lang`) or `?lang=en`.
- **Hot-reload saves**: the collector re-reads `settings.cfg` every round, so saving no
  longer restarts it (no data gap).
- **Atomic config writes** (`tmp` → JSON validation → `rename`).
- **Configurable warn/hot thresholds** (`warn`, `hot` in `settings.cfg`); they only affect
  colours and log hints.
- **Dual-pane UI** — all HDDs left, all SSDs right, responsive down to 1024 px.
- **Unsaved-changes bar**, 0-drive save rejection, CSV export / clipboard copy.
- **`bin/selftest.sh`** — 18 read-only checks, 34 with `--full` (injection, fail-safe
  timing, mode switching, container restart).
- Status badge distinguishes running / stopped / stale data.

### Changed
- Collector accepts a `hot` threshold from the config (default 50 °C) for `WARN` log lines.
- Event log rotation triggers at 1000 lines or 128 KB, rotating back to 500 lines.
- Log timestamps use the host `date` (identical to the collector's clock).

### Removed
- **Stop button** in the UI (stop via User Scripts on array stop, or `lib/control.php stop`).
- Pause feature (was never shipped).
- 860 px fixed width, dark cards on a light page, per-disk tables split across two scroll areas.

### Fixed
- Page disappeared from the Settings menu when the file was saved with CRLF line endings
  (`build_pages()` splits the header on the literal `\n---\n`).
- Drawer could not open because `#cct .drawer` outranked `body.cct-drawer .drawer`.
- `3 前` / `0 秒前` freshness labels; `0 err` mixed-language leftovers.

## [2.2.0] — 2026-08

- Single-file page, dual-page i18n (中文 / English `.page`).
- avg/max aggregation, ring-buffer event log, array-slot ordering, variable-spinup HDD
  detection (`ATA Version is:` fallback).

## [1.0.0] — 2026-07-30

- First release: HDD/SSD temperature collection, avg/max, WebUI.
