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
