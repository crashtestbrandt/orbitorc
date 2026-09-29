# The command line

`orbitorc <verb> [args] [options]`. It talks to the control plane over its JSON API; nothing it does is
special, and it runs from anywhere.

## Getting it

| | |
| --- | --- |
| Standalone | The `orbitorc-cli-<os>-<arch>` artifact from CI, or `mix escript.build` in `apps/orbitorc_cli`. Needs Erlang on the machine, nothing else. Put it on `PATH`; a consumer project's task runner aliases its verbs to it. |
| From the checkout | `mix orbitorc <verb>` at the umbrella root, the same code. |

## Verbs

| Verb | Lease | |
| --- | --- | --- |
| `doctor` | | Every box, from the fleet's cache. |
| `doctor --box NAME` | | One box, asked fresh. |
| `sync REV PROJECT [--box NAME \| --all]` | yes | Every named box (default: all) to one revision, and say whether they agree. A branch name is the remote's branch (`sync main` is `origin/main`); a sha or tag is itself. Needs no manifest in the checkout: a sync is how a checkout gets one, and the box serves it as soon as the sync returns; a manifest with `sync.import` then has the box import the tree. |
| `lease claim\|renew\|release --box NAME [--ttl S]` | | Take, extend or give up a box. |
| `launch PROJECT MODE --box NAME\|--all [--param k=v …] [--headless] [-- game args]` | yes | Launch a mode the project declares. `--all` is every box reporting `launch.PROJECT.MODE`. |
| `dry-run PROJECT MODE --box NAME\|--all [--param k=v …] [-- game args]` | | The exact argv the box would run, and nothing launched. |
| `status --box NAME` | | What the box is running, and who holds it. |
| `logs JOB --box NAME [--tail N] [--grep RE] [--follow]` | | A job's log, live or finished. `--follow` prints the tail and then every line the box writes until the job exits, over the control plane's event stream. |
| `stop JOB --box NAME` | yes | One job. |
| `stop --box NAME\|--all [--force]` | yes | Every job this caller started, on one box or every box. `--force` takes everyone's. |
| `build PROJECT TARGET --box NAME\|--all` | yes | The project's own build recipe, with the artifact asserted against its floor. `--all` is every box reporting `export.TARGET`. |
| `shot JOB --box NAME [--window HINT]` | yes | Capture one window. Never the screen. |
| `pull JOB --box NAME [--file NAME] [--out DIR]` | | Fetch an artifact to where you are standing. |
| `verdict JOB PROJECT --box NAME` | | Did that job measure anything. |
| `run PROJECT [--authority-mode MODE] [--load-mode MODE] [--measure S] [--link MODE] [--load-per-box N] [--authority-box NAME] [--load-box NAME …] [--seed N] [--allow-colocated] [--wait]` | takes its own | A whole fleet run. `--wait` follows it to its verdict. The authority mode defaults to `server` and the load mode to `bench`; a project whose manifest names them differently says so here. |
| `run-status ID` | | A run's snapshot and timeline. |
| `runs` | | Live runs, then history. |
| `upgrade TAG\|URL --box NAME\|--all [--sha256 HEX]` | yes | Replace each agent with a release: fetched, verified against its checksum, swapped, restarted by its service manager. A box with a job running refuses. |

## Targets

`--box NAME` is one box. `--all` is every connected box that can serve the verb. A fan-out reports one
block per box and exits non-zero if any box refused:

```
win
  job 4  pid 9120  ready when the log shows "SMOKE net=client"
mac
  REFUSED: bench renders and this box has no graphical session (no DISPLAY or WAYLAND_DISPLAY)
```

## Passthrough

Everything after a bare `--` is the game's own argv, appended after everything the manifest built. It
works on `launch` and `dry-run`, and a dry run shows it in place:

```sh
orbitorc dry-run spaceman scene --box win --param scene=tools/instr/orbit_travel_scene_probe.tscn -- --arena=orbit-travel --no-combat-spawn
```

## Options

| | |
| --- | --- |
| `--caller NAME` | Who is asking. Defaults to `$USER@hostname`, or `$ORBITORC_CALLER`. It is what the lease arbitrates between and what the audit log attributes to; an anonymous mutation would make both useless. |
| `--url URL` | The control plane. Defaults to `$ORBITORC_URL`, else `http://localhost:4000`. |
| `--param k=v` | A launch parameter. Repeatable. A numeric-looking value is coerced, because an integer that stays a string builds a different argv than the one intended. |
| `--headless` | Run a rendering mode without a window: bot fleets, display-less boxes. |
| `--json` | The raw response. |

## A first session

```sh
orbitorc doctor                                          # who is connected, and what each would refuse
orbitorc doctor --box win                                # the checks, fresh
orbitorc dry-run orbitnet server --box win               # read the argv before committing a box to it
orbitorc lease claim --box win
orbitorc launch orbitnet server --box win
orbitorc status --box win                                # ready, and how long it took
orbitorc logs 3 --box win --tail 40
orbitorc stop 3 --box win
orbitorc lease release --box win
```

And a run, which takes its own leases:

```sh
orbitorc run orbitnet --authority-box win --load-box mac --measure 30 --load-per-box 4 --wait
```
