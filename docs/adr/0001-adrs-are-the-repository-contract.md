# ADR-0001 — Architecture decisions are recorded as ADRs, and the accepted ADRs are the repository contract

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-04 |
| Applies to | every repository built from this one, and every change to it |
| Enforced by | review (CODEOWNERS) |
| Related | [ADR-0005](0005-repository-layout-and-shared-tooling.md) |

## Context

This repository is the reference implementation of a set of conventions: the repository layout, the build, the
configuration tree, the CI/CD workflows and the runtime operations of Spring Boot applications. Teams reuse those
conventions in two ways: they add an app to this repository, or they create a new repository from it
([ADR-0005](0005-repository-layout-and-shared-tooling.md)). Both work only if the conventions are written down as
rules that a change can be checked against, together with the reasons behind them.

A convention that exists only in code is broken by the first change that does not know about it. A convention that
exists only in prose is not enforced. A single living "standards" document loses the reasoning and silently
changes the contract whenever somebody edits it.

This series replaces the repository's earlier decision records, which described changes relative to a
predecessor codebase rather than the design as it stands. They remain in the git history.

## Decision

1. **One decision per file.** Each architecture decision is one file `docs/adr/NNNN-<slug>.md`, identified as
   `ADR-NNNN`. Numbers are assigned in sequence and never reused or renumbered. ADR-0001 to ADR-0999 are the
   **contract**: they are shared by every repository built from this one. A repository's own decisions — those that
   do not belong to the contract — are numbered from ADR-1000.
2. **Format.** Every ADR has a header table (Status, Date, Applies to, Enforced by, Related) and the sections
   *Context*, *Decision*, *Alternatives considered* and *Consequences*.
3. **Normative language.** The *Decision* section states rules with the keywords MUST, MUST NOT, SHOULD,
   SHOULD NOT and MAY in the sense of RFC 2119. The rules are the contract; the other sections explain them.
4. **The contract is the set of ADRs whose status is Accepted.** It applies to every app in this repository and to
   every repository built from this one, unless an ADR narrows its scope in *Applies to*.
5. **Lifecycle.** Proposed → Accepted → Superseded by ADR-NNNN, or Deprecated. An accepted ADR is not edited in
   substance. A changed decision is a new ADR that supersedes the old one, and the old one's status names its
   successor. Status changes, links and corrections that do not change a rule are the only edits allowed.
6. **Enforcement.** *Enforced by* names the automated checks that fail when a rule is broken: a config-lint check,
   a Gradle task, a script's validation, a CI job or a test. "Review" means only code review enforces it. A rule
   that is enforced only by review SHOULD get an automated check.
7. **The index is the living part.** [`docs/adr/README.md`](README.md) lists the ADRs with their status and a
   one-line summary of each rule. It also holds the checklists for adding an app and creating a repository, the
   **known gaps** (places where the tree does not conform yet), and the **open decisions**. Gaps are tracked
   there, not by editing ADRs.
8. **Changes keep the contract.** A pull request that changes behaviour governed by an ADR either conforms to it,
   or adds the ADR that supersedes it in the same pull request. It also updates the known gaps when it closes or
   opens one.
9. **References.** Code, configuration and documentation cite rules by ADR number (for example
   `ADR-0012`). They never cite documents outside this repository.

## Alternatives considered

- **One living standards document.** Easy to read, but every edit silently changes the contract, the reasons are
  lost, and nothing shows which rule changed when.
- **Design documents in a wiki or another repository.** They drift from the code, are not reviewed with it, and
  are not available to a repository created from this one.
- **ADRs without normative rules.** These are explanations, not a contract: a change cannot be checked against
  them.

## Consequences

- A newcomer reads the index, then the ADRs of the area they touch.
- Changing a convention costs a new ADR. That friction is intended: it makes a changed contract visible.
- A repository created from this one carries ADR-0001 to ADR-0999 unchanged and records its own decisions from
  ADR-1000. Its deviations from the contract are recorded as ADRs that say what they deviate from.
- Some comments in code and configuration still cite identifiers of retired documents; they are to be replaced by
  ADR numbers (known gap in the index).
