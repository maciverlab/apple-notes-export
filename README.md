# Apple Notes weekly export (macOS + Colima + Docker + launchd)

Headless weekly export of Apple Notes to HTML/JSON via
[`apple_cloud_notes_parser`](https://github.com/threeplanetssoftware/apple_cloud_notes_parser),
running under Colima (not Docker Desktop) and scheduled with `launchd`.

**Full documentation, including incident history and troubleshooting:**
[`docs/full_notes_export_with_colima.md`](docs/full_notes_export_with_colima.md)

## Layout

| Path | Purpose |
|---|---|
| `run_combined_export.sh` | Main script: weekend/cooldown gates, DB copy, parser run, memory sampler, failure alerts |
| `launcher/` | Source and build script for `notes-export-launcher`, the small compiled program `launchd` runs. It starts `run_combined_export.sh` and holds the **Full Disk Access** grant |
| `run_with_terminal.sh` | Legacy helper that opens the export in a visible Terminal window. Not used by `launchd` |
| `test_time_logic.sh` | Exercises the scheduling window logic |
| `launchd/` | The two LaunchAgents (4-hourly export check; Colima autostart at login) |
| `docs/` | Canonical documentation |

## Not in this repo, by design

`.gitignore` is a **whitelist**. The working directory also contains
`NoteStore.sqlite` (~112 MB copy of the personal Notes database) and `output/`
(every exported note as HTML/JSON). Neither may ever be committed. Add new
tracked files explicitly rather than loosening the ignore rules.

## Security notes

Read [the security section of the docs](docs/full_notes_export_with_colima.md#-security-notes)
before copying this setup. In short:

- **`~/NotesIndex/bin/notes-export-launcher` needs Full Disk Access.** macOS grants file
  access to the program `launchd` starts, so this small compiled launcher holds the grant and
  the export script runs under it. A grant on the `.sh` file itself does nothing, because the
  program actually running is `/bin/bash`. Anyone who can edit `run_combined_export.sh` can
  run code with that access, so keep the script writable only by you.
- **The parser image is pinned by digest and run with `--network none`.** It receives a full
  copy of your Notes database; an unpinned tag would mean trusting the registry on every run,
  and no network means a compromised image cannot exfiltrate anything.
- **Never put container output into the failure alert text** — it is built by AppleScript
  string interpolation and would become an injection point.

## How it runs

`launchd` fires `bin/notes-export-launcher` every 4 hours, which runs
`run_combined_export.sh`. The script exits
immediately unless it is inside the weekend window (Sat 00:00 → Mon 04:59)
**and** at least 5.25 days have passed since the last *successful* export.
There is no catch-up: a weekend with the Mac powered off skips that week.

## Quick health check

```bash
date -r $(cat ~/NotesIndex/.last_successful_export)     # last SUCCESSFUL run
grep -c "\[START\]"          ~/Library/Logs/notes-export-full.log
grep -c "Docker completed OK" ~/Library/Logs/notes-export-full.log
grep "Peak container memory"  ~/Library/Logs/notes-export-full.log | tail -3
```

A `[START]` without a matching `Docker completed OK` is a failed run.
Exit code 137 means the Colima VM ran out of RAM — see the troubleshooting section.
