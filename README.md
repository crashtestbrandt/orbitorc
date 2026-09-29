![OrbitOrc](docs/img/banner.png)

<sub>Godot render. Earth surface from NASA Visible Earth (Blue Marble Next Generation), city lights from NASA
Earth Observatory (Black Marble 2016) and Milky Way from NASA/SVS *Deep Star Maps 2020*. Star positions from the Yale Bright Star Catalog, 5th edition.</sub>

# OrbitOrc

Network orchestration for multiplayer games, at indie scale.

Large studios test netcode on a fleet: a build goes to many machines, a session comes up across them,
bots drive it under a chosen link, and every machine's metrics come back to one place. Unreal's
Gauntlet and Riot's Backend Validation Service are that shape. OrbitOrc is the same shape for a team
that has a few spare boxes instead of a device lab.

**The single-box bench is not the measurement you think it is.** Running a server and its clients on
one machine conditions a loopback socket and puts every process in contention for the same cores. It
cannot produce a real link's bandwidth cap, a NAT, or the shape of a relayed transport — and a
server-side cost measured while its own clients saturate the box describes the harness, not the
netcode. OrbitOrc puts the server on one machine and the load on others.

## What it is

| | |
| --- | --- |
| **Control plane** | A Phoenix application. A dashboard, a JSON API, and the socket every agent connects into. Run history in SQLite — no server to provision. |
| **Agent** | A small BEAM release on each machine. It dials **out** to the control plane, so a box needs no inbound firewall rule, no SSH key and no static hostname. |
| **Manifest** | An `orbitorc.json` each project ships at its own root, declaring what may be launched. OrbitOrc launches nothing it was not told about. |

## Why the BEAM

Orchestrating a fleet is supervising hundreds of long-running processes across machines, reacting to
each one's output, and tearing all of them down correctly when any of it fails. That is what OTP is.

- **Supervision is teardown.** The worst failure in a harness like this is an orphaned process holding
  a UDP port, poisoning the next run in a way that reads as a netcode bug. Every launched process has
  an owner in a supervision tree, and a dead owner is a dead process.
- **A run is a state machine**, not a shell script with signal traps: bring up the authority, wait for
  its marker, bring up the link, fan out the load, measure, collect, judge.
- **Log lines are messages.** Readiness, failure detection and the live dashboard all read the same
  stream, rather than three pieces of code polling three copies of a file.

## Three rules it is built on

- **Readiness is a marker, never a sleep.** Each mode declares the line that proves it came up. A
  fixed sleep is either too short on a cold cache or wasted on a warm one, and it cannot tell "slow"
  from "failed".
- **Every job writes a log file.** A GUI-subsystem binary on Windows never attaches stdout, so
  redirection alone loses the log on exactly the platform a remote fleet exists to reach.
- **Game traffic never rides the control plane.** The control plane may cross a VPN; the session under
  measurement uses the LAN address, because routing it through WireGuard would put encryption and a
  userspace hop inside the thing being measured.

## Where to start

| | |
| --- | --- |
| [docs/manifest.md](docs/manifest.md) | What a project declares, and how the argv is built from it. |
| [docs/agent.md](docs/agent.md) | Configuring a box, installing into its graphical session, what it reports and what it refuses. |
| [docs/runs.md](docs/runs.md) | What a fleet run does, phase by phase, and what to read when it fails. |
| [docs/cli.md](docs/cli.md) | Every verb. |

```sh
mix setup                       # dependencies, the database, assets
mix phx.server                  # the control plane, on every interface at :4000
mix orbitorc doctor             # who is connected
mix escript                     # the standalone command line: apps/orbitorc_cli/orbitorc
```

CI builds the agent, the control plane and the command line for Linux, macOS and Windows on every
push, and attaches them to a release on a tag. `flake.nix` builds the agent for NixOS.

## License

Dual-licensed under Apache-2.0 or MIT, at your option. See [LICENSE](LICENSE).
