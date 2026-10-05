# ADR-0026 — Integration-test data are versioned test cases, with expected output in canonical form

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | every integration-test case under `test-infra/testdata/` |
| Enforced by | the framework's tests (`CanonicalJsonTest`, `RowSetComparatorTest`); the integration tests themselves |
| Related | [ADR-0006](0006-apps-and-framework-modules.md), [ADR-0008](0008-versions-derived-from-git.md), [ADR-0025](0025-integration-tests-on-compose-stacks.md) |

**In short:** Each integration-test case is a directory of plain files: a manifest, the input data and the expected
rows. The expected rows are stored in one canonical JSON form, so reviewers read them as data. Shared comparators
decide what counts as equal, with explicit tolerances, and a failure says what differed.

## Context

The expected output of an integration test is data, and it should be reviewed as data, not hidden in assertion
code. Results from real systems carry noise: row order, ingestion timestamps, float formatting, clock skew.
Comparisons have to tolerate exactly that noise and nothing else. And a failure has to say what differed.

## Decision

1. **One directory per case:** `test-infra/testdata/<AppName>/<case>/`.
   - `manifest.yml` describes the case:
     - `case`, `connector` (the AppName), `instance`, `datasetVersion`;
     - `input`: `database`, `schema`, `seed[]`;
     - `expected`: `target`, `table`, `file`;
     - `compare`: `keyColumns`, `ordered`, `ignoreColumns`, `timestampTolerance`, `numericTolerance`, `timeout`.
   - `input/*.sql` holds the schema and seed files. Each is a single batch with no `GO` separator, so it can be
     applied over JDBC or by the seed helper.
   - `expected/*.jsonl` holds the expected rows as canonical JSON Lines, without the ignored columns.

   `instance` names the `local` instance whose configuration the case runs with
   ([ADR-0025](0025-integration-tests-on-compose-stacks.md)).
2. **Canonical JSON.** Canonical means that each value has exactly one written form, so equal data gives equal text:
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

   Every comparison writes two reports to `build/reports/integrationTest/`: `<case>-diff.json` (missing rows,
   unexpected rows, per-column differences, duplicate keys) and `<case>-actual.jsonl` (the actual rows in canonical
   form). A mismatch fails the test, and the assertion message lists a bounded number of differences.

   One test case, from its manifest to the verdict:

   ```mermaid
   flowchart TD
     load["Load the case<br/>TestCase reads manifest.yml"] --> seed["Seed the inputs<br/>input/*.sql"]
     seed --> poll["Poll the target table"]
     poll --> enough{"Expected row count present?"}
     enough -->|not yet, time left| poll
     enough -->|yes, or timeout expired| compare["Convert to canonical JSON,<br/>compare once with expected/*.jsonl"]
     compare --> reports["Write {case}-diff.json<br/>and {case}-actual.jsonl"]
     reports --> match{"Rows match?"}
     match -->|yes| pass["Pass"]
     match -->|no| fail["Fail, listing a bounded<br/>number of differences"]
   ```

4. **Shared fixtures.** The framework's test fixtures are test helpers that every app's tests can use. They provide
   `TestCase`, `CompareRules`, `RowSetComparator`, `ComparisonResult`, `CanonicalJson`, `ItEnvironment` and
   `ActuatorClient` ([ADR-0006](0006-apps-and-framework-modules.md)). Apps MUST use them instead of hand-written
   comparisons.
5. **Seed helpers.** Generic per-dependency setup, such as creating databases, lives in
   `test-infra/seed/<dependency>/` and is applied inside the dependency's container. Case-specific data lives in the
   case.
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
