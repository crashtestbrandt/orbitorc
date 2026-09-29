# Changelog

Every release, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) as CLAUDE.md
describes it for this project. A tag `vX.Y.Z` on `main` is a release; CI attaches the agent, the
control plane and the command line for Linux, macOS and Windows to it.

## [Unreleased]

### Added

- `upgrade`: replace an agent with a release, from the command line (`orbitorc upgrade v0.2.0 --all`)
  or the dashboard. The box fetches the archive CI attached for its platform, verifies the checksum
  beside it, swaps and exits; its service manager restarts it. A box with a job running refuses.
- The report carries `arch` and `agent_version`; the fleet page and `orbitorc fleet` show them.
- CI attaches a `.sha256` beside every release archive.

## [0.1.0] - 2026-09-29

The first release.

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

[Unreleased]: https://github.com/crashtestbrandt/orbitorc/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/crashtestbrandt/orbitorc/releases/tag/v0.1.0
