# ADR-0026 — Integration-test data are versioned cases with canonical expected output

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | every integration-test case under `test-infra/testdata/` |
| Enforced by | the framework's tests (`CanonicalJsonTest`, `RowSetComparatorTest`); the integration tests themselves |
| Related | [ADR-0006](0006-apps-and-framework-modules.md), [ADR-0008](0008-versions-derived-from-git.md), [ADR-0025](0025-integration-tests-on-compose-stacks.md) |

## Context

The expected output of an integration test is data, and it should be reviewed as data, not hidden in assertion
code. Results from real systems carry noise: row order, ingestion timestamps, float formatting, clock skew.
Comparisons have to tolerate exactly that noise and nothing else, and a failure has to say what differed.

## Decision

1. **One directory per case:** `test-infra/testdata/<AppName>/<case>/`:

   ```
   manifest.yml        the case: case, connector (the AppName), instance, datasetVersion,
                       input {database, schema, seed[]}, expected {target, table, file},
                       compare {keyColumns, ordered, ignoreColumns, timestampTolerance, numericTolerance, timeout}
   input/*.sql         schema and seed files: single batches, no GO, appliable over JDBC or by the seed helper
   expected/*.jsonl    the expected rows, canonical JSON Lines, without the ignored columns
   ```

   `instance` names the `local` instance whose configuration the case runs with
   ([ADR-0025](0025-integration-tests-on-compose-stacks.md)).
2. **Canonical JSON.**
   - Keys are sorted, and there is no insignificant whitespace.
   - Numbers are plain decimals, without exponent or trailing zeros.
   - Timestamps are ISO-8601 UTC with milliseconds.
   - `null` is written out.

   Expected files are written in this form. Actual rows are converted to it before comparing.
3. **Comparison rules** (from the manifest's `compare` block):
   - rows are matched as a set on `keyColumns`, unless `ordered`;
   - a duplicate key is a failure;
   - `ignoreColumns` are dropped;
   - timestamp and numeric columns match within their tolerances;
   - the test polls until the expected row count is present or `timeout` expires, then compares once.

   A failure writes `<case>-diff.json` (missing rows, unexpected rows, per-column differences, duplicate keys), and
   the assertion message lists a bounded number of items in each category.
4. **Shared fixtures.** The framework's test fixtures provide `TestCase`, `CompareRules`, `RowSetComparator`,
   `ComparisonResult`, `CanonicalJson`, `ItEnvironment` and `ActuatorClient`
   ([ADR-0006](0006-apps-and-framework-modules.md)). Apps MUST use them instead of hand-written comparisons.
5. **Seed helpers.** Generic per-dependency setup, such as creating databases, lives in `test-infra/seed/<dependency>/`
   and is applied inside the dependency's container. Case-specific data lives in the case.
6. **Versioning.** A dataset's major version follows the project's major version
   ([ADR-0008](0008-versions-derived-from-git.md)). An incompatible change to a case's data or format goes with a
   breaking release.

## Alternatives considered

- **Expected values written in test code.** The data can't be reviewed as data, and every test invents its own
  comparison.
- **Snapshot files in whatever format the system emits.** Diffs full of noise from ordering, formatting and
  timestamps.

## Consequences

- Reviewers read a test case's inputs and expectations as files.
- What counts as "equal" is explicit and the same for every app.
- The format fits tabular outputs (tables, topics). An app with a different kind of output adds its comparator to
  the framework's fixtures, so every app can use it.
