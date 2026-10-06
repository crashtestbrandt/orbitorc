# Changelog

Every release, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) as CLAUDE.md
describes it for this project. A tag `vX.Y.Z` on `main` is a release; CI attaches the agent, the
control plane and the command line for Linux, macOS and Windows to it.

## [Unreleased]

### Fixed

- `--box` can be repeated. It kept only its last value, so `sync main p --box a --box b` synced b alone
  and reported that every box agreed. A verb that fans out now reaches every box named; a verb that acts
  on one box refuses a second.
- `doctor --all` asks every box fresh. It answered from the fleet's cache, so a box that had just been
  re-imported still read as stale. A bare `doctor` is still the cache.

## [0.4.1] - 2026-10-06

### Fixed

- A sync takes the remote's tags. A tag re-created on the remote made the fetch refuse ("would clobber
  existing tag"), and that box failed every sync until someone fixed its checkout by hand.
- The sync and upgrade results on the fleet page keep the box name in its own column. A long refusal
  squeezed it until the name ran into the commit beside it.
- A tag's release carries its notes once. Each platform's build published the release, and every one
  after the first appended its generated notes again; one job now publishes it.

## [0.4.0] - 2026-10-06

### Added

- An agent's configuration takes an optional `lan`: the IPv4 address other machines join the box at. Set
  it on a box with more than one network. Anything that is not a dotted IPv4 address refuses to load.
- `install/windows-control-plane.ps1` installs a control plane on Windows: a boot task as LOCAL SERVICE
  that needs no logon and is restarted if it stops, with Erlang distribution off and the port admitted
  from the local subnet only.

### Fixed

- An agent on Windows no longer advertises a Hyper-V adapter as its LAN address. Windows names every
  interface by device path, so the name filter matched nothing there, and a new virtual switch that
  enumerated first was joined by nobody. Adapters with Hyper-V's MAC prefix (`00:15:5D`) are skipped.

- A control plane on Windows listens on IPv4. An IPv6 listener there is IPv6-only and Erlang cannot
  clear that (`ipv6_v6only: false` is `einval`), so it answered `::1` and no agent could join it.

- The macOS installers retry `launchctl bootstrap`: launchd unloads a service asynchronously, and a
  bootstrap that lands while the previous instance is still being removed fails with "Input/output
  error", which is what a reinstall hit.

## [0.3.2] - 2026-09-30

### Fixed

- The released command line refused to start for want of `DATABASE_PATH`: the escript evaluates the
  umbrella's runtime configuration, whose control-plane block now runs only where a control plane is
  present. CI runs the built escript to prove it starts.
- `install/*.sh` are executable.
- The release no longer forces SSL: it answered every `ws://` agent upgrade and every `http://` page from
  any host but localhost with a 301 to an https port nothing listens on, so only the box beside the
  control plane could join. TLS is a proxy's job in front of the process.
- `PHX_HOST` names the address the dashboard is opened at and is allowed as a socket origin (with
  localhost); a control plane opened at its LAN address refused every dashboard socket, and each page
  reconnected by long polling until the process ran out of file descriptors.

### Added

- `install/macos-control-plane.sh`: the control plane as a LaunchAgent, with its environment in
  `control-plane.env` and the file limit raised past launchd's 256.

## [0.3.1] - 2026-09-29

### Fixed

- The agent release runs no distribution and starts no epmd. On Windows an epmd started by the previous
  release outlived it and held the release directory, so an upgrade's swap failed and, unchecked, moved
  the staged release inside the old one while logging success. The swap script now stops whatever still
  runs out of the release, checks each move, and logs a failed swap as one.

## [0.3.0] - 2026-09-29

### Added

- `run --authority-mode MODE --load-mode MODE` on the command line, and the same two fields on the runs
  page. The API took them already; a project whose authority mode is not called `server` could not be run
  from the command line.
- `sync.import` in a manifest: the box imports the engine project after every sync, so a renamed class
  does not resolve to `Variant` out of the previous checkout's cache. The sync's reply says so.

### Fixed

- A job that exited within milliseconds of its launch could take the job registry down (the registry
  asked itself for the job's directory); it now reads the record under its own root.
- A report that raises no longer takes the link down; it is logged.

## [0.2.0] - 2026-09-29

### Added

- `upgrade`: replace an agent with a release, from the command line (`orbitorc upgrade v0.2.0 --all`)
  or the dashboard. The box fetches the archive CI attached for its platform, verifies the checksum
  beside it, swaps and exits; its service manager restarts it. A box with a job running refuses.
- The report carries `arch` and `agent_version`; the fleet page and `orbitorc fleet` show them.
- CI attaches a `.sha256` beside every release archive.

## [0.1.0] - 2026-09-29

The first release. Its tag carries no build artifacts (CI lacked the permission to attach them);
0.2.0 is the first release with them.

### Added

- A control plane (`orbitorc`): the socket agents dial into, a JSON API, a dashboard, run history.
- An agent per box (`orbitorc_agent`): dials out, supervises what it launches, reports what the box can
  serve and what would make a result untrustworthy.
- A manifest, `orbitorc.json`, that a project ships at its root to declare what a box may launch.
- A command line (`orbitorc`): every verb, `--all` fan-out, `--` passthrough, `--json`, `--follow`.
- A dashboard with every verb the command line has: sync, doctor, lease, launch, dry run, build, stop,
  shot, verdict, pull, a live log per job, and a form that starts a run.
- Fleet runs: an authority on one box, load on the others, readiness by marker, a measured verdict.
- Health checks a box reports before a launch: checkout revision and cleanliness, engine version,
  import-cache freshness, declared requirements, LFS pointers, pinned backends.

[Unreleased]: https://github.com/crashtestbrandt/orbitorc/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/crashtestbrandt/orbitorc/releases/tag/v0.4.1
[0.4.0]: https://github.com/crashtestbrandt/orbitorc/releases/tag/v0.4.0
[0.3.2]: https://github.com/crashtestbrandt/orbitorc/releases/tag/v0.3.2
[0.3.1]: https://github.com/crashtestbrandt/orbitorc/releases/tag/v0.3.1
[0.3.0]: https://github.com/crashtestbrandt/orbitorc/releases/tag/v0.3.0
[0.2.0]: https://github.com/crashtestbrandt/orbitorc/releases/tag/v0.2.0
[0.1.0]: https://github.com/crashtestbrandt/orbitorc/releases/tag/v0.1.0
