# OrbitOrc — Claude Code context

## Writing for humans

Everything written for a human reader — PR titles, commit messages, issue and review comments, release
notes, the README, every page under `docs/`, and module documentation — is **concise, bulleted and
aphorism-free**. State plainly what changed and what it now does.

- No metaphor, euphemism, or oblique stand-in for the thing you mean.
- No epigrams or rhetorical inversions ("A *X* is not a *Y*", "not *X*, but *Y*").
- No teaser clause joined by a colon to the real content.
- No emphatic capitalization, and no general truth standing in for the specific change.
- Short sections, bullets over paragraphs, tables for enumerations, identifiers in backticks. Record
  the rule and its consequence; skip the narrative of how it was discovered. Bold the term a rule is
  about.

A reader who has not seen the diff must learn what changed from the sentence alone.

**A PR title is a release-notes line.** Form: `<type>(<area>) <plain description> (#issue)`, type one
of `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `chore`; area is the part of the system
the change lands in (`manifest`, `agent`, `run`, `fleet`, `web`, `api`, `release`, `ci`, …).

## Write for a reader who has only this repository

This is a public repository. It orchestrates projects it knows nothing about.

- **Never name a downstream project**, its classes, scenes, arenas, weapons, issue numbers or docs
  pages. A reader cannot resolve any of them, and a module comment carries the reasoning rather than
  pointing at it.
- Where a concrete example earns its place, describe it in general terms: "a bot client that joins and
  simulates nothing" rather than the name of the game that did it.
- Anything a project needs to declare about itself belongs in its own `orbitorc.json`, never in a
  table here.

## Rules the code enforces

- **A manifest is data, never code.** An agent already runs an engine binary out of a synced checkout.
  It will not also evaluate code from one.
- **Readiness is a marker, never a sleep.**
- **Every job writes a log file.**
- **Launch the raw engine binary, never a wrapper script.** A wrapper that runs the engine inside a
  process substitution orphans it when killed, and the orphan keeps its UDP port bound.
- **Game traffic never rides the control plane.**

## Versions

The project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). One number, in
`VERSION` at the root; every `mix.exs` reads it, and a tag `vX.Y.Z` on `main` must equal it or CI
attaches nothing.

**The public surface** — what a version number is a promise about:

| Surface | Where it is defined |
| --- | --- |
| The manifest, `orbitorc.json` (`schema` and every key) | `Orbitorc.Manifest`, `docs/manifest.md` |
| The agent's configuration file and install units | `Orbitorc.Agent.Config`, `install/`, `docs/agent.md` |
| The agent–control plane protocol: verbs, payloads, the report | `Orbitorc.Agent.Link`, `OrbitorcWeb.AgentChannel` |
| The JSON API and the command line's verbs and flags | `OrbitorcWeb.Verbs`, `OrbitorcWeb.Router`, `Orbitorc.CLI`, `docs/cli.md` |
| The run's spec and snapshot | `Orbitorc.Run`, `docs/runs.md` |

**Which number moves:**

- **Major** — a change that breaks one of those surfaces: a manifest key removed or renamed, a verb or
  flag removed, a payload or report shape changed so that an older agent and a newer control plane (or
  the reverse) cannot work together. Before `1.0.0` a breaking change moves the minor instead, and the
  changelog says so in its first line.
- **Minor** — a new verb, flag, manifest key, check or page; anything an older client ignores safely.
- **Patch** — a fix that changes no surface.

**How a release is cut:**

1. The PRs that land in it are already the release notes: each title is one line of them.
2. Bump `VERSION`; move the `Unreleased` entries in `CHANGELOG.md` under the new version with the date;
   commit as `chore(release) vX.Y.Z`.
3. Tag `vX.Y.Z` on `main` and push the tag. CI checks the tag against `VERSION`, builds the agent, the
   control plane and the command line for Linux, macOS and Windows, and attaches them to a GitHub release
   with generated notes.

An agent and a control plane on different minors are expected to work together within a major; a PR
that makes that untrue is a breaking change and says so in its title.
