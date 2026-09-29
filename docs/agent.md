# The agent

A small BEAM release on each machine. It dials **out** to the control plane and stays connected. Nothing
connects to a box, so a box needs no inbound firewall rule, no SSH key and no static hostname — a
laptop on a hotel network joins the same way a rack machine does.

The socket is the presence. A box that loses power leaves the fleet at once; there is no heartbeat
table to fall behind and no timeout to tune.

## Configuration

A file **on the box**, never something a caller can change over the wire. A remote caller drives what
the box already offers and nothing more.

| Platform | Path |
| --- | --- |
| macOS | `~/Library/Application Support/orbitorc/config.json` |
| Linux | `${XDG_CONFIG_HOME:-~/.config}/orbitorc/config.json` |
| Windows | `%LOCALAPPDATA%\orbitorc\config.json` |

```json
{
  "control_plane": "wss://orbitorc.example.net/agent/websocket",
  "name": "win-gpu",
  "token": "…",
  "game_port": 47900,
  "relay_port": 47910,
  "job_retention": 200,
  "projects": [
    { "name": "orbitnet", "repo": "C:/boxes/orbitnet", "engine_bin": "C:/engines/Godot_v4.7-stable_win64.exe" }
  ]
}
```

| Key | |
| --- | --- |
| `control_plane` | Where the agent dials out to. `wss://` is verified against the system trust store. |
| `name` | How this box appears in the fleet. The control plane holds one token per name; a box may only join as the name its token belongs to. A release reads them from `ORBITORC_AGENT_TOKENS=name=token,…`; a development control plane reads them from a gitignored `config/dev.local.exs`. |
| `projects` | Each with its **own checkout and its own engine binary**. Never a checkout a CI runner shares: a runner deletes and re-fetches its tools mid-job, which would remove the engine from under a live measurement. |
| `game_port` / `relay_port` | The band a job binds. Keep it clear of the ports a project's own harnesses use on the same machine, so a job here never makes an unrelated probe fail to bind. |
| `job_retention` | Job directories to keep. Ids never repeat; the lowest are pruned at start, and the agent says which. |

A project whose checkout has no usable `orbitorc.json` is reported, not fatal: the box still serves
the others and `doctor` names the one that is not. A box with no configuration at all starts idle and
says so — a box that vanishes from the fleet says nothing about why.

## Install into the graphical session

A process launched outside the graphical login session gets a non-interactive window station on
Windows, no display on Linux and no Aqua session on macOS. **A rendering job launched that way draws
nothing and reports success.** That is the failure the install scripts exist to prevent.

| Platform | What the script installs | Why |
| --- | --- | --- |
| macOS | A LaunchAgent (`install/macos-install.sh`) | A LaunchDaemon runs in the System domain and can never present a window. |
| Linux | A systemd **user** unit bound to `graphical-session.target` (`install/linux-install.sh`) | A system service has no `DISPLAY`. |
| Windows | A scheduled task, at logon, as the interactive user (`install/windows-install.ps1`) | A service runs in session 0, which has no window station. |

A box with no display at all is still useful — a sync, a build and a headless authority are all valid
there. It reports "headless modes only" and refuses the rendering ones.

Build the release on a machine of the target platform: `MIX_ENV=prod mix release orbitorc_agent`.
The agent release carries the domain and the agent and nothing else: no Phoenix, no assets, no
database, and no need for the control plane's secrets.

## What the box reports

`mix orbitorc doctor --box <name>` asks the box fresh. The report is deliberately wide: not "is the agent
up" but "would a job launched here produce a result anybody should believe".

| Check | What it catches |
| --- | --- |
| Graphical session | A rendering job that draws nothing and reports success. |
| Checkout revision, branch, dirty count | Two boxes in one session running different code, which reads as a netcode disagreement. A dirty tree is named, not refused. |
| Engine version | A version skew that changes physics or serialization under the measurement. |
| Import freshness | A stale class cache resolves a class name to nothing; the project dies at parse time or comes up empty. This is the one that produces a metrics file full of zeros. The report names the newer file. |
| Declared requirements | A native library the project needs and this checkout has never built. Every class it registers resolves to nothing, so the job dies at load or comes up empty. |
| LAN address | What other machines join. Never a tunnel, never a bridge. |
| Capabilities | `launch.<project>.<mode>` per mode, `export.<target>`, `shot`. What a verb is checked against before it crosses the wire. |

Every check is reported, never fatal.

## What the box refuses

The control plane decides who may ask; the box decides what it will do. Every request is checked twice.

- A mutating verb — launch, stop, sync, build, shot — needs the **lease**. Read verbs — doctor, status,
  logs, pull, verdict — never do, so a caller who cannot take the box can still watch.
- A lease is one per box, expires on its TTL and on agent restart, and nothing breaks one early. A
  force-break verb would be used by whichever caller was most confident, which is not the same as
  whichever caller was right.
- A rendering mode on a box with no session, unless forced headless.
- A mode the manifest does not declare; a parameter it marks required and the caller left out; a
  scene path that leaves the tree.
- A verb whose handler crashes answers the error and **stays connected**. A bug in one verb must not
  drop the box out of the fleet.

Every action is appended to `audit.jsonl` beside the configuration: caller, verb, arguments, result.
Tokens never reach it.

## Jobs

A job is an engine process owned by a supervised Elixir process. **Supervision is teardown**: the
owner kills the OS process in `terminate/2`, so a job dies when it is stopped, when its supervisor
restarts, and when the agent goes down. Closing a port does not kill its child, so the OS pid is
recorded at launch and killed explicitly.

Each job has a directory: `job.log` (the engine's own log), `job.json` (argv, pid, readiness, exit
status — the difference between reading a result and guessing what produced it), and any artifacts the
mode wrote there. A finished job is still readable: a bench client self-terminates when its window
closes, and its results are read after that.

Readiness is the mode's marker appearing in `job.log`, never a sleep. The tail is flushed on exit, so a
job that printed its marker and exited within a millisecond — a smoke does exactly that — is not
reported as having died before it was ready.
