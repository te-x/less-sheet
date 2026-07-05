# Contract Change Request — <feature> / <symbol @ file:line>

Signed:  [ ] implementer   [ ] reviewer
(both required; the reviewer's signature also certifies the numbers below were independently re-checked)

## Grounds (tick at least one)
- [ ] A. Infeasible within the current contract
- [ ] B. Substantial, quantified improvement

## If A — infeasibility
- Attempts (≥2), each with the specific reason it failed under the current signature:
  1.
  2.
- Failing gate / compiler / type-checker output:

## If B — improvement
- Dimension: performance | memory | code-size/complexity | correctness
- Baseline (current contract):  <measurement or LOC>
- Proposed:                     <measurement or LOC>
- Magnitude:                    <e.g. ~10x faster / −200 LOC across 5 call sites>
- Evidence (how measured):      <benchmark command + numbers / prototype diff / count>
- Reviewer's independent check: <reviewer re-ran it and got: ...>

## Minimal change (as a diff)
<exact new signature/type — the smallest change that achieves the above>

## Cost / blast radius
- Other contract items / tests / modules affected:
- Changes EXTERNAL I/O?   [ ] no    [ ] yes → this goes to the ARCHITECT, not the planner.
