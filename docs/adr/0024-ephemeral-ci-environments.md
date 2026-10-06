# ADR-0024 — CI test environments are throwaway, labelled with their run, and always torn down

| | |
|---|---|
| Status | Accepted. Rule 5 superseded in part by [ADR-0035](0035-dev-envs-and-reference-app-are-optional.md), rule 2 in part by [ADR-0041](0041-every-label-prefix-derives-from-the-group.md) |
| Date | 2026-10-04 |
| Applies to | every compose stack and kind cluster a workflow creates |
| Enforced by | the `leak-check` steps of `compose-stack` and `kind-cluster` (fail the job when anything of the run remains); the nightly teardown drill |
| Related | [ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md), [ADR-0019](0019-kubernetes-and-helm-are-provisional.md), [ADR-0021](0021-ci-layering.md), [ADR-0025](0025-integration-tests-on-compose-stacks.md) |

**In short:** Every CI job creates its own compose stack or kind cluster, named and labelled after its run. The
environment is torn down whether the job passes, fails or is cancelled, and a leak check fails the job if anything
is left behind. A nightly drill proves that this cleanup works.

## Context

Integration tests and deployment tests need real containers, networks, volumes and clusters. A shared, long-lived
test environment collects state, runs contend for it, and tests turn flaky. A resource left behind by a failed or
cancelled run is a leak that the next run trips over.

## Decision

1. **One environment per job.** Every stack or cluster is created for one job and named after the run:
   - compose project `ci-<run_id>-<run_attempt>`;
   - kind cluster `ci-<run_id>-<run_attempt>`, or `deploy-<run_id>-<run_attempt>` in the dev deploy.

   No test environment is shared between runs, and CI publishes no ports.
2. **Everything is labelled.** Every container, network and named volume carries the labels `com.example.ci.run`
   and `com.example.ci.attempt`. Some images declare volumes; those are replaced by labelled named volumes or
   `tmpfs`, so no anonymous volume escapes the labels. The app template carries the same labels
   ([ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md)).

   > **Superseded in part by [ADR-0041](0041-every-label-prefix-derives-from-the-group.md) rule 6.** The run labels
   > are `<group>.ci.run` and `<group>.ci.attempt`, the group being `projects[0].group` of `platform.yml`; the kind
   > nodes carry `<domain>/ci.run` and `<domain>/ci.attempt`, the domain being the group reversed.

3. **Teardown always runs.** It is an `always()` step, so it runs on success, failure and cancellation:
   - `stack.sh down` and `kind.sh down` remove the environment, then prune by label;
   - `leak-check` fails the job when anything carrying the run's labels remains.

   The job fixes the cluster or project name, not `up`. So teardown finds the environment even when `up` never
   finished.
4. **Diagnostics before teardown.** On failure, diagnostics are collected and uploaded as an artifact. Then the
   environment is torn down:
   - compose: `ps`, logs and health of every service, `stats`;
   - kind: nodes, events, descriptions and logs of failing pods, Helm history, `kind export logs`.

   Whatever happens to the job, its environment ends in teardown and the leak check:

   ```mermaid
   flowchart TD
     name["The job names the environment<br/>after its run"] --> up["up: start the stack or cluster"]
     up --> work["Run the tests, or the dev deploy"]
     work -->|success| down["down: remove the environment,<br/>then prune by label"]
     up -->|failure| diag["Collect diagnostics,<br/>upload them as an artifact"]
     work -->|failure| diag
     diag --> down
     up -.->|cancel| down
     work -.->|cancel| down
     down --> leak["leak-check: fail the job if anything<br/>labelled with the run remains"]
   ```

5. **The guarantee is tested.** The nightly teardown drill starts the reference stack. It proves that teardown and
   the leak check leave the runner clean in two cases:

   > **Superseded in part by [ADR-0035](0035-dev-envs-and-reference-app-are-optional.md) rule 7.** The drill runs only
   > when `platform.yml` declares a `reference_app`.

   - a test fails on purpose;
   - the run cancels itself.

   Every ordinary run proves the passing case.

## Alternatives considered

- **A shared integration environment.** Contention, state left over between runs, and failures that depend on what
  ran before.
- **Testcontainers** (the test JVM owns the lifecycle). Resources are reaped with the JVM, but a laptop and CI
  would run different stack definitions. See [ADR-0025](0025-integration-tests-on-compose-stacks.md).
- **Best-effort cleanup.** It proves nothing, and leaks surface as unrelated failures in later runs.

## Consequences

- Every run starts from nothing and leaves nothing. Failures are reproducible.
- Each job pays the start-up time of its stack or cluster.
- The design relies on ephemeral GitHub-hosted runners. A persistent self-hosted runner would need the same labels,
  plus a sweep of anything an interrupted runner left behind.
