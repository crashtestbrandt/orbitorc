# A fleet run

`mix orbitorc run <project>` brings a whole session up across machines, measures it, and judges what came
back. It is the reason the project exists.

## The placement rule

**The authority gets a box to itself, and the load goes elsewhere.** A server measured while its own
clients saturate the same machine produces a number that describes the harness, not the netcode. With
one box connected a run refuses:

```
the only box that can serve bench is dev, which is running the authority — load on the same
machine measures the harness, not the netcode. Connect a second box, or pass allow_colocated.
```

`--allow-colocated` overrides it, for a smoke of the run itself rather than a measurement.

## Phases

```
placing → authority → link → load → measuring → collecting → done | failed
```

| Phase | What happens | What ends it |
| --- | --- | --- |
| `placing` | Pick the authority's box and the load boxes. **Claim the lease on every box** before touching any. | Leases held, or a refusal. |
| `authority` | Launch the authority mode, headless. | Its ready marker, forwarded from the box as an event. |
| `link` | If `--link <mode>`: launch the conditioned link on the authority's box, targeting the authority's LAN address. | Its ready marker. |
| `load` | Launch `--load-per-box N` clients on each load box, joining the link's port if there is one, else the authority's. `metrics: auto` lands each client's CSV in its own job directory. | Every client's ready marker. |
| `measuring` | Nothing. The clients run their window. | Every client exiting on its own. |
| `collecting` | Ask each load box for its client's verdict. | `done` if none is vacuous; `failed` naming the boxes otherwise. |

Then every job the run launched is stopped, every lease released, and the run's process ends. Its last
snapshot is the record.

## Nothing is a sleep

Bringup waits on the marker. The window waits on the clients finishing. Each carries a deadline —
90 s for a marker, the window plus 60 s for the clients — and **a deadline firing is a failure with a
name**, not the normal way a phase ends:

```
no ready marker within 90s from win job 12
past the window and its grace, still running: mac job 4
```

A job that exits before its marker fails the run at once, naming it; the run does not wait out the
deadline to report a marker that never arrived. A box leaving the fleet mid-run fails it at once,
naming the box.

## What to read when it fails

`mix orbitorc run-status <id>` or the run's page shows the **timeline**: each phase, when it began, and
what the run learned in it. The useful question is never "did it fail" but "how far did it get, and
what did it see last".

| Failure | Where to look |
| --- | --- |
| Refused at placement | `mix orbitorc doctor`: which boxes report `launch.<project>.<mode>`, and whether the load mode needs a session the box lacks. |
| Authority exited before ready | `mix orbitorc logs <job> --box <box>`: usually a parse error. `doctor` will have flagged a stale import cache or a missing requirement first. |
| No marker within 90 s | The mode's `ready` line in the manifest against what the log actually prints. |
| Client measured nothing | The verdict's detail names the columns that stayed zero. The client joined and simulated nothing — an import cache, a missing library, or a seat count exceeded. |
| Box left the fleet | The box's own agent log. |

## Ports and addresses

Load joins the authority at the **LAN address the authority's box reports**, never whatever path the
control plane took to reach it. A session routed through a VPN measures the VPN. The ports are the
ones the box declares, not guessed.

## What a run does not do

It does not evaluate a project's own bench rules. It pulls nothing back by itself. A project that folds
server-side counters into a CSV and judges them with its own tool does that after the run, on the
artifacts `mix orbitorc pull <job> --box <box>` fetches. The verdict a run applies is only the one every
project shares: did each client simulate anything at all.
