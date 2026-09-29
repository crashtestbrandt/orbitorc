# The manifest — `orbitorc.json`

What a project may launch, declared as data at the root of its own repository. An agent reads it out
of the checkout it was pointed at. **A manifest is data, never code**: an agent already runs an engine
binary out of a synced checkout, which is a trust boundary; it will not also evaluate code from one.

OrbitOrc launches nothing it was not told about. A checkout with no manifest serves nothing.

## Top level

| Key | Required | |
| --- | --- | --- |
| `schema` | yes | `1`. An unknown value is refused by name rather than half-read. |
| `project` | yes | The name the fleet knows the project by. |
| `engine_project` | | Directory holding the engine's project file, relative to the checkout. `.` (default) when the root is the project. |
| `ports` | | `{"game": 47900, "relay": 47910}`. Informational; the box's own configured band is what a launch uses. |
| `checks` | | What a job here needs in order to mean anything. See below. |
| `sync` | | How the project builds. See below. |
| `measurement` | | Which columns testify that a client simulated. See below. |
| `events` | | How to read `key=value` events out of a log. See below. |
| `modes` | yes | What may be launched. See below. |

Keys beginning with `_` are comments and are ignored.

## `modes`

One entry per thing a box may launch.

| Key | |
| --- | --- |
| `ready` | The line that proves the mode came up. A run waits on it. Empty or absent means the mode has no universal ready line and is reported as launched. |
| `gui` | The mode renders, so it needs a graphical session. A box with none refuses it unless the launch is forced headless. |
| `env` | Added to the job's environment. |
| `engine` | Arguments before the `--`, where the engine reads them. `--headless` belongs here for a mode that never draws. |
| `script` | Run this script instead of the main scene (`-s`). |
| `scene` | A scene path, positional, before the `--`. The one thing no other position can name. Validated on the box: it must be inside the checkout. |
| `argv` | Arguments after the `--`, where the game reads them. |
| `defaults` | Values for parameters the caller left out. |
| `required` | Parameters with no default that the caller must supply. A missing one refuses the launch, naming it. |

Every job also gets the engine's own log flag, pointed inside the job's directory. A GUI-subsystem
binary on Windows never attaches stdout, so redirection alone loses the log on exactly the platform a
remote fleet exists to reach.

### Substitution

A token in `engine` or `argv` is a string, or `{"arg": "...", "if": "param", "unless": "param"}`.

- `{name}` and `{dotted.name}` interpolate a parameter.
- **A token whose placeholder has no value is dropped whole.** That is what makes an optional flag
  optional without a branch per flag.
- A token with no placeholder is always emitted.
- `if` emits the token only when that parameter is truthy; `unless` suppresses it when that parameter
  has a value. Together they express a fallback flag that applies only when a richer one was not given.
- **Zero is a value, not an absence.** A duration or a seed of `0` is a real instruction, and dropping
  it would run a different job than the one asked for. `nil`, `false` and `""` are absences.
- A whole number formats without a trailing `.0`.

### Parameters the box fills in

| Parameter | |
| --- | --- |
| `port`, `listen` | If the mode declares a default for it and the caller did not send one, the box substitutes its own configured game or relay port. That keeps a job off the ports a project's own harnesses bind on the same machine. |
| `metrics`, `record`, `replay` | `"auto"` becomes a real file inside the job's own directory. A caller never names a path on a machine it cannot see. |
| `scene` | Normalized to `res://…` and refused if it leaves the tree. |

## `checks`

```json
"checks": { "requires": ["addons/orbitnet_native/bin", "demos/arena/addons/orbitnet"] }
```

Paths, relative to the checkout, that a job here needs in order to mean anything. These are not where
a build lands; they are what must already be present. A native library is the one whose absence ruins
a run quietly: every class it registers resolves to nothing, so the project dies at load or comes up
empty and writes a metrics file of zeros. An empty directory does not satisfy a requirement — it is
what a cleaned build leaves behind.

A required file that is a **Git LFS pointer** is missing: a checkout made without LFS leaves a 130-byte
text stub where the library should be, and the stub satisfies every existence check while the engine
fails three steps away with an invalid header. The stub's first line names itself, so it is read rather
than measured.

The box reports each missing path in `doctor`, and the dashboard flags it, before anything is launched.

```json
"checks": {
  "requires": ["addons/orbitnet_native/bin"],
  "pinned": [{ "lock": "orbitnet.lock", "stamp": "addons/orbitnet_native/.fetched" }]
}
```

`pinned` is for a project that vendors a native backend as a pinned release and records what it
installed in a stamp beside the library: the tag, then the lock file's own sha256. A box synced to one
commit and then moved to another whose lock names a different tag still holds the old libraries, and
the failures that produces look like anything except a stale library. The check compares the stamp's
second field to the lock's sha256 — offline, without hashing a byte of the library — and reports
`stale-backend` with "run sync". A missing lock is not ok: nothing then says what is installed.

## `sync`

```json
"sync": { "build": ["just", "native-install"], "build_dir": "addons/orbitnav_native/bin", "build_min_bytes": 262144 }
```

| Key | |
| --- | --- |
| `build` | The project's own build command, run in the checkout. `{target}` is replaced by the requested export target. OrbitOrc does not know how a project builds. |
| `build_dir` | Where a build lands. The `build` verb asserts something appeared there. |
| `build_min_bytes` | A floor on the artifact's size. A build that "succeeded" and produced a stub is the shape that reaches a measurement and reports a confident wrong answer. |
| `import` | `true` to import the engine project after every sync, so the class cache the next launch resolves through is this tree's. A synced tree with the previous checkout's cache resolves a renamed class to `Variant` and dies at parse time, reported as a server that never printed its marker. A cold project is imported twice; the cache file, not the engine's exit status, is the verdict. |

`sync` itself is `git fetch`, `git checkout --force <revision>`, `git reset --hard`. Anything
uncommitted is gone, which is intended: every machine in a fleet must run the same code. That is why a
sync needs the lease.

## `measurement`

```json
"measurement": {
  "artifact": "metrics.csv",
  "evidence": ["resim_ticks", "reconcile_error"],
  "known_other": ["tick", "rtt_ms", "tx_bytes_s"],
  "judged_modes": ["bench"]
}
```

A client that joins and simulates nothing still writes a full metrics file. The transport columns
carry real numbers; every simulation column is flat zero. That reads as "joined cleanly, simulated
nothing", which is indistinguishable from a regression in the branch under test.

- `evidence` is an **allow-list** of columns that testify to a live simulation. Listing the columns to
  ignore instead reads better but fails the wrong way: a new transport column carrying data would rescue
  a run in which nothing simulated.
- `known_other` are columns the verdict knows are not evidence. A column in neither list is named as
  unclassified, so the gap is visible rather than silent.
- `judged_modes` are the modes that *can* move the evidence. A dedicated server has no predicted body
  and writes zeros by construction; accusing it would be a false accusation. A mode not listed answers
  `unknown`, never `vacuous`.

A project that declares nothing here answers `unknown` for every run. `unknown` is not a pass, and it
is never an accusation.

## `events`

```json
"events": { "pattern": "^SMOKE (\\w+)=(\\S+)", "ignore": ["pos", "aim"] }
```

How to read `key=value` events out of a job's log, so a status query can answer "did a peer actually
connect" without pulling the whole file. Two capture groups: key, value. `ignore` drops per-tick
telemetry keys that would otherwise bury the handful of lines anybody wants.

## Two real manifests

A netcode addon's, with an authority, a conditioned link and a bot client:

```json
{
  "schema": 1,
  "project": "orbitnet",
  "engine_project": "demos/arena",
  "checks": { "requires": ["addons/orbitnet_native/bin", "demos/arena/addons/orbitnet"] },
  "measurement": { "artifact": "metrics.csv", "evidence": ["resim_ticks", "reconcile_error"], "judged_modes": ["bench"] },
  "modes": {
    "server": {
      "ready": "-STATE PLAYING", "gui": false,
      "env": { "ORBITNET_DEBUG": "1" },
      "engine": ["--headless"],
      "argv": ["--dedicated={port}", "--quit-after={quit_after}"],
      "defaults": { "port": 47900, "quit_after": 200 }
    },
    "relay": {
      "ready": "RELAY: bound", "gui": false,
      "script": "res://addons/orbitnet/bench/relay_main.gd",
      "argv": ["--relay-listen={listen}", "--relay-target={target}", "--relay-profile={profile}"],
      "defaults": { "listen": 47910, "profile": "congested_wifi" },
      "required": ["target"]
    },
    "bench": {
      "ready": "-STATE PLAYING", "gui": true,
      "argv": ["--join={join}", "--bench", "--bench-bot={bot}", "--bench-metrics={metrics}", "--bench-duration={duration}"],
      "defaults": { "bot": "strafe", "duration": 25 },
      "required": ["join"]
    }
  }
}
```

A library addon's, whose jobs are smokes on each platform rather than a session across machines:

```json
{
  "schema": 1,
  "project": "orbitnav",
  "engine_project": "harness",
  "checks": { "requires": ["addons/orbitnav_native/bin", "harness/addons/orbitnav"] },
  "sync": { "build": ["just", "native-install"], "build_dir": "addons/orbitnav_native/bin", "build_min_bytes": 262144 },
  "modes": {
    "smoke": { "ready": "", "gui": false, "engine": ["--headless"], "argv": ["--quit-after={quit_after}"], "defaults": { "quit_after": 120 } },
    "scene": { "ready": "", "gui": true, "scene": "{scene}", "required": ["scene"] }
  }
}
```

The test suite parses whichever sibling manifests are checked out beside this repository and asserts
every mode they declare builds an argv. It fails if it finds none.
