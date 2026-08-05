# Reflect eval: seeded-contradiction detection

Frontier models detect stale/contradicted memory at only about 55% on published benchmarks
(the STALE result). `bash tests/run.sh` cannot judge whether the reflect skill's LLM half
actually catches a contradiction; it can only pin the deterministic scaffolding around it
(see the "reflect-scope includes a freshly committed contradiction-pair page" case in
`tests/run.sh`). This protocol is the agentic half: run it by hand, or wire it into an
agent-graded CI lane, whenever the reflect skill's prompt or A2 step changes.

## Setup

1. Create a scratch wiki (`wiki-setup` against a throwaway directory, or reuse an existing
   disposable fixture wiki with git history).
2. Seed the contradiction pair from `tests/fixtures/contradiction-a.md` and
   `tests/fixtures/contradiction-b.md` into the scratch wiki as `entities/relay-node.md` and
   `concepts/relay-node-defaults.md` respectively (same paths the deterministic test in
   `tests/run.sh` uses).
3. `git add -A && git commit` so the pair is git-tracked (reflect-scope only considers
   committed pages).

## Run

4. Run `python3 hooks/reflect-scope.py` against the scratch wiki and confirm both pages
   appear in the printed scope (this should already hold; it is the deterministic pin).
5. Invoke the `reflect` skill's Phase A against that scope, per `skills/reflect/SKILL.md`.

## Expected outcome

- The reflection log written to `analyses/reflection-<date>.md` contains a `contradiction`
  finding that names BOTH pages (`entities/relay-node.md` and
  `concepts/relay-node-defaults.md`).
- That finding carries the classification `genuine-contradiction`: both pages describe the
  Relay Node's current default port and disagree (8080 vs 9090), not a case where the world
  moved between the two timestamps.
- The finding lands as a normal checkbox edit-proposal (per SKILL.md, `genuine-contradiction`
  and `version-difference` are the two classifications that get a proposed edit), not filed
  under one of the unchecked judgment-call headings.

## Grading

Score PASS only if all three expected-outcome bullets hold. Any other classification
(`version-difference`, `scope-difference`, `terminology-difference`,
`unresolved-uncertainty`), a missing finding, or a finding naming only one page is a FAIL:
record the actual classification and the model's stated reason, since a wrong call here is
exactly the failure mode this eval exists to catch.
