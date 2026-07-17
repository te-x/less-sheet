# Contract Change Request — <feature> / <decision or symbol @ file:line>

Signed:  [ ] implementer   [ ] reviewer
(both required; the reviewer's signature certifies the evidence below was independently re-checked)

## Request kind (tick one)
- [ ] Contract / public boundary
- [ ] Technology / architecture decision

## Grounds (tick at least one)
- [ ] A. Infeasible within the current contract
- [ ] B. Substantial, quantified improvement
- [ ] C. Approved technology cannot meet a signed requirement, or has a security/licensing/compatibility problem

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

## If C — technology / architecture evidence
- Current approved decision:
- Signed requirement it cannot meet:
- Evidence (failure, advisory, licence, compatibility matrix, or measured result):
- Reviewer's independent check:

## Minimal requested change
- Contract diff: <exact new signature/type, or "unchanged">
- Decision to reopen: <name the approved choice; the architect researches and recommends any replacement>
- After architect + human sign-off, updated ARCH/PROJECT reference: <pending until approved>

## Cost / blast radius
- Other contract items / tests / modules affected:
- Changes EXTERNAL I/O?   [ ] no    [ ] yes → this goes to the ARCHITECT, not the planner.
- Adds/replaces an architecture-significant technology or production dependency?
  [ ] no    [ ] yes → name it and route the decision to the ARCHITECT + human.
