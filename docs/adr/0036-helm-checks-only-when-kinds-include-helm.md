# ADR-0036 — config-lint requires the Helm artefacts only when `platform.yml` kinds includes `helm`

| | |
|---|---|
| Status | Accepted. Supersedes in part rules 2 and 5 of ADR-0019, rule 5 of ADR-0011 and rule 2 of ADR-0014 (rule 5) |
| Date | 2026-10-06 |
| Applies to | config-lint checks 3, 4 and 12; the charts and the `_helm-values.*.yaml` files of every repository built from this one |
| Enforced by | `ConfigLint.kt` (one `helmEnabled` value, read from `platform.yml` `kinds`, consulted by checks 3 and 12); `ConfigLinterTest` |
| Related | [ADR-0010](0010-image-tags-digests-promotion-retention.md), [ADR-0011](0011-configuration-tree-and-spring-layers.md), [ADR-0014](0014-config-lint-enforces-the-config-contract.md), [ADR-0019](0019-kubernetes-and-helm-are-provisional.md), [ADR-0029](0029-release-and-promotion.md), [ADR-0030](0030-platform-yml-declares-every-project-value.md) |

**In short:** `kinds` in `platform.yml` names the runtimes of a project. config-lint now asks for a chart per app
and the Helm values of every instance only when `kinds` includes `helm`. Without it, check 12 renders nothing and no
Helm 4 is needed. A values file that exists anyway is still checked, so a stale image tag in it still fails. This
repository keeps `kinds: [compose, helm]`, so nothing changes here.

## Context

Every env runs on on-prem compose, and Helm is kept working but not extended
([ADR-0019](0019-kubernetes-and-helm-are-provisional.md)). Yet config-lint demanded the Helm artefacts whatever
`kinds` said. Check 12 failed in `local` when an app had no chart, and warned in every other env. Check 3 required
`_helm-values.app.yaml` and `_helm-values.instance.yaml`. Check 12 ran `helm lint`, `helm template` and kubeconform
per instance, and with `CI=true` a missing Helm 4 failed the task.

config-lint already read `kinds` ([ADR-0030](0030-platform-yml-declares-every-project-value.md)), but only check 11
used it, to refuse a `kind: helm` target. So a repository built from this one with `kinds: [compose]` could never
deploy with Helm, yet had to carry a chart per app, two values files per instance and Helm 4 on its runner. The
owner decided that the Helm and kind tier is an opt-in extension of the template.

## Decision

1. **`kinds` switches the Helm checks.** config-lint MUST derive one value, "Helm is a runtime", from `kinds` and
   consult it wherever a check needs a Helm artefact. When `kinds` includes `helm`, every check, number and message
   stays as it was.
2. **Without `helm`, nothing Helm is required.**
   - Check 12 MUST NOT require a chart: no error in the complete envs, no warning elsewhere.
   - Check 3 MUST NOT require `_helm-values.app.yaml` or `_helm-values.instance.yaml`.
   - Check 12 MUST NOT render: no `helm lint`, no `helm template`, no kubeconform, so CI needs no Helm 4.
   - Check 11 keeps refusing a `kind: helm` target.
3. **A values file that exists is still checked.** Without `helm`, a `_helm-values.*.yaml` is optional, but one
   that exists MUST pass the checks it always had: it parses (check 3), its `identity` and `env:` restate the path
   and its `image.tag` equals `IMAGE_TAG` (check 4), and its tags follow the tag policy (check 10). The version bump
   rewrites `image.tag` in such a file ([ADR-0029](0029-release-and-promotion.md)), and the retention sweep keeps
   every tag it names ([ADR-0010](0010-image-tags-digests-promotion-retention.md)), so a stale copy is not harmless.
   A repository that drops Helm SHOULD delete the files.
4. **Said once.** When the Helm checks are skipped, the summary line of `configLint` says so and names the `kinds`
   it read. No finding is reported per file.
5. **What this supersedes, in part:**
   - [ADR-0019](0019-kubernetes-and-helm-are-provisional.md) rule 2 (the values "required by config-lint check 3")
     and rule 5 (every new app ships a chart, and every instance its values): both hold only when `kinds` includes
     `helm`;
   - [ADR-0011](0011-configuration-tree-and-spring-layers.md) rule 5: `_helm-values.app.yaml` and
     `_helm-values.instance.yaml` are required only when `kinds` includes `helm`;
   - [ADR-0014](0014-config-lint-enforces-the-config-contract.md) rule 2: checks 3, 4 and 12 apply to the Helm
     artefacts as rules 2 and 3 here say.

## Alternatives considered

- **Reject a values file when Helm is off.** Strict, but a repository that pauses Helm would have to delete files it
  may want back, in the same pull request that changes `kinds`.
- **Ignore a values file when Helm is off.** The version bump and the retention sweep still read it, so its tag
  would drift unseen.
- **Use `-PconfigLint.helm=none`.** It already exists, but it only switches the renderer off; the chart and the
  values stay required. The runtimes are a project value, and `platform.yml` holds them.
- **A new key in `platform.yml`.** `kinds` already says it, and a value is declared once
  ([ADR-0030](0030-platform-yml-declares-every-project-value.md)).

## Consequences

- This repository keeps `kinds: [compose, helm]`, so its checks, findings and report are unchanged.
- The Helm and kind tier is the opt-in extension of the template, by the owner's decision. A repository built from
  this one with `kinds: [compose]` needs no chart, no values file and no Helm 4 to pass config-lint.
- The shared Helm tooling (`scripts/helm-deploy-instance.sh`) stays in such a repository, unused, because shared
  tooling is copied unchanged ([ADR-0005](0005-repository-layout-and-shared-tooling.md)). `config-lint.yml` still
  installs Helm 4 and kubeconform; config-lint does not call them.
- Opting in later is a change of `kinds` plus a chart per app and the values of every instance; config-lint then
  requires them again.
- The checklists of the index mark the chart and the values files "when `kinds` includes `helm`".
