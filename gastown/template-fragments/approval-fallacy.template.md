{{ define "approval-fallacy-crew" }}
## No Approval Step

When work is done, finish the cycle. Do not summarize and wait for permission.

- Commit and push your work.
- Continue with the next task, or send handoff context and exit:
  `gc mail send -s "HANDOFF: <brief>" -m "<context>" && gc runtime drain-ack && exit`
- Do not ask "should I commit this?"
- Do not sit idle after finishing.
{{ end }}

{{ define "approval-fallacy-polecat" }}
## No Idle Polecats

When implementation and checks are done, hand off immediately through the
formula. There is no approval wait. An idle polecat blocks the refinery and
wastes the pool slot.

### The Done Sequence Lives in the Formula

The `mol-polecat-work` `submit-and-exit` step is the single source of truth for
handoff — branch-shape gate, push + push-verify, metadata, refinery
reassignment, wake/nudge, and drain. **Run that step.**

**Do NOT run submit-and-exit twice** — running the done sequence twice is a bug.
Do not trust memory for this; check mechanically. Derive the work bead from your
convoy exactly as the formula's workspace-setup step does — never pass a bare or
guessed id to `bd`, which fuzzy-matches and can reassign the wrong bead.
`$GC_BEAD_ID` is the convoy the molecule was poured on, and when it is not
exported the block below recovers the convoy from the step bead you are holding.
Only positive evidence — the work bead closed, or handed to the refinery —
means submit-and-exit already reassigned it. Otherwise run it:

```bash
SUBMITTED_SH="{{ .ConfigDir }}/assets/scripts/polecat-already-submitted.sh"
if [ -f "$SUBMITTED_SH" ]; then
  bash "$SUBMITTED_SH" "{{ .BindingPrefix }}"
else
  echo "SUBMITTED_GUARD_MISSING already-submitted script not found at '$SUBMITTED_SH'; no evidence the handoff ran, so run submit-and-exit."
fi
```

The check lives in this pack's assets/scripts/polecat-already-submitted.sh; run it, do not retype or read it first. If it prints `ALREADY_SUBMITTED` it has already drain-acked: stop and exit. Anything else is no evidence that the handoff ran: run submit-and-exit.

The push gate is handled inside submit-and-exit itself, and it fails closed:
`auto_push=false` halts at branch-ready (no push, no refinery handoff); an
ABSENT `auto_push` on a bead whose DESCRIPTION or NOTES assert a no-push rail
also halts, and escalates, because absent metadata is not consent; metadata the
gate cannot decode halts and escalates as well (`metadata_unreadable`), because
unreadable metadata is not absent metadata — it is a recorded decision the gate
failed to retrieve — as does an `auto_push` value outside the closed vocabulary
(`false`/`no`/`0` halt, `true`/`yes`/`1` push, case-folded), because a decision
the gate cannot understand is not consent either; consent pushes and reassigns
to the refinery.

Polecats do not push to main, close beads, create MR beads, or wait around. If
work appears already merged, still let submit-and-exit reassign it to the
refinery — only the refinery verifies patch identity and closes beads.
{{ end }}
