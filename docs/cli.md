# The command line

`mix orbitorc <verb> [args] [options]`, run from a checkout of this repository. It talks to the control
plane over its JSON API; nothing it does is special.

## Verbs

| Verb | Lease | |
| --- | --- | --- |
| `doctor` | | Every box, from the fleet's cache. |
| `doctor --box NAME` | | One box, asked fresh. |
| `sync REV PROJECT [--box NAME …]` | yes | Every named box (default: all) to one revision, and say whether they agree. |
| `lease claim\|renew\|release --box NAME [--ttl S]` | | Take, extend or give up a box. |
| `launch PROJECT MODE --box NAME [--param k=v …] [--headless]` | yes | Launch a mode the project declares. |
| `dry-run PROJECT MODE --box NAME [--param k=v …]` | | The exact argv the box would run, and nothing launched. |
| `status --box NAME` | | What the box is running, and who holds it. |
| `logs JOB --box NAME [--tail N] [--grep RE]` | | A job's log, live or finished. |
| `stop JOB --box NAME` / `stop --box NAME --all [--force]` | yes | One job, or every job this caller started. `--force` takes everyone's. |
| `build PROJECT TARGET --box NAME` | yes | The project's own build recipe, with the artifact size asserted. |
| `shot JOB --box NAME [--window HINT]` | yes | Capture one window. Never the screen. |
| `pull JOB --box NAME [--file NAME]` | | Fetch an artifact into the current directory. |
| `verdict JOB PROJECT --box NAME` | | Did that job measure anything. |
| `run PROJECT [--measure S] [--link MODE] [--load-per-box N] [--authority-box NAME] [--load-box NAME …] [--seed N] [--allow-colocated] [--wait]` | takes its own | A whole fleet run. `--wait` follows it to its verdict. |
| `run-status ID` | | A run's snapshot and timeline. |
| `runs` | | Live runs, then history. |

## Options

| | |
| --- | --- |
| `--caller NAME` | Who is asking. Defaults to `$USER@hostname`. It is what the lease arbitrates between and what the audit log attributes to; an anonymous mutation would make both useless. |
| `--url URL` | The control plane. Defaults to `$ORBITORC_URL`, else `http://localhost:4000`. |
| `--param k=v` | A launch parameter. Repeatable. A numeric-looking value is coerced, because an integer that stays a string builds a different argv than the one intended. |
| `--headless` | Run a rendering mode without a window: bot fleets, display-less boxes. |
| `--json` | The raw response. |

## A first session

```sh
mix orbitorc doctor                                          # who is connected, and what each would refuse
mix orbitorc doctor --box win                                # the checks, fresh
mix orbitorc dry-run orbitnet server --box win               # read the argv before committing a box to it
mix orbitorc lease claim --box win
mix orbitorc launch orbitnet server --box win
mix orbitorc status --box win                                # ready, and how long it took
mix orbitorc logs 3 --box win --tail 40
mix orbitorc stop 3 --box win
mix orbitorc lease release --box win
```

And a run, which takes its own leases:

```sh
mix orbitorc run orbitnet --measure 30 --load-per-box 4 --wait
```
