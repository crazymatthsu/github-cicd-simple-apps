# ADR-0024 — CI test environments are ephemeral, labelled per run, and always torn down

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | every compose stack and kind cluster a workflow creates |
| Enforced by | the `leak-check` steps of `compose-stack` and `kind-cluster` (fail the job when anything of the run remains); the nightly teardown drill |
| Related | [ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md), [ADR-0019](0019-kubernetes-and-helm-are-provisional.md), [ADR-0021](0021-ci-layering.md), [ADR-0025](0025-integration-tests-on-compose-stacks.md) |

## Context

Integration tests and deployment tests need real containers, networks, volumes and clusters. A shared,
long-lived test environment collects state, contends between runs and turns flaky. A resource left behind by a
failed or cancelled run is a leak that the next run trips over.

## Decision

1. **One environment per job.** Every stack or cluster is created for one job and named after the run:
   - compose project `ci-<run_id>-<run_attempt>`;
   - kind cluster `ci-<run_id>-<run_attempt>`, or `deploy-<run_id>-<run_attempt>` in the dev deploy.

   No test environment is shared between runs, and CI publishes no ports.
2. **Everything is labelled.** Every container, network and named volume carries `com.example.ci.run` and
   `com.example.ci.attempt`. Volumes that images declare are replaced by labelled named volumes or `tmpfs`, so no
   anonymous volume escapes the labels. The app template carries the same labels
   ([ADR-0017](0017-run-compose-operations-cli-and-runtime-posture.md)).
3. **Teardown always runs.** It is an `always()` step, so it runs on success, failure and cancellation:
   - `stack.sh down` and `kind.sh down` remove the environment, then prune by label;
   - `leak-check` fails the job when anything carrying the run's labels remains.

   The cluster or project name is fixed by the job, not by `up`, so teardown finds it even when `up` never
   finished.
4. **Diagnostics before teardown.** On failure they are collected and uploaded as an artifact, then the environment
   is torn down:
   - compose: `ps`, logs and health of every service, `stats`;
   - kind: nodes, events, descriptions and logs of failing pods, Helm history, `kind export logs`.
5. **The guarantee is tested.** The nightly teardown drill starts the reference stack and proves that teardown and
   the leak check leave the runner clean in two cases:
   - a test fails on purpose;
   - the run cancels itself.

   Every ordinary run proves the passing case.

## Alternatives considered

- **A shared integration environment.** Contention, state left over between runs, and failures that depend on
  what ran before.
- **Testcontainers** (lifecycle owned by the test JVM). Resources are reaped with the JVM, but a laptop and CI would
  run different stack definitions. See [ADR-0025](0025-integration-tests-on-compose-stacks.md).
- **Best-effort cleanup.** No proof, and leaks surface as unrelated failures in later runs.

## Consequences

- Every run starts from nothing and leaves nothing. Failures are reproducible.
- Each job pays the start-up time of its stack or cluster.
- The design relies on ephemeral GitHub-hosted runners. A persistent self-hosted runner would need the same
  labels, plus a sweep of anything an interrupted runner left behind.
