#!/usr/bin/env bash
# retention.sh — GHCR image retention (ADR-0010). Dry run by default. Another registry: exit 0 with a notice (ADR-0032).
#
# Usage: retention.sh [--dry-run | --delete] [--owner <owner>] [--repo <owner/repo>] [--package <name>]...
#   --package   container package, e.g. github-cicd-simple-apps/source-database (repeatable). Default: every
#               project that builds an image (scripts/ci/projects.py, ADR-0031) under the project of platform.yml
#               (ADR-0010).
# Rules, per package version (one version = one digest with its tags):
#   pr-<n>-<sha7>   deleted once pull request #<n> has been closed (merged or not) for PR_GRACE_DAYS days
#   *-rc.<n>        the RC_KEEP newest are kept, and every one younger than RC_MIN_AGE_DAYS; the rest go
# Never deleted:
#   - a version carrying a tag that config/**/_docker-compose.instance.env (IMAGE_TAG) or
#     config/**/_helm-values.instance.yaml (tag:)
#     references on this checkout, or that the last successful GitHub Deployment of a dev env names (its
#     payload's tag and images; the dev tree itself declares `main`, ADR-0027) — the in-use protection;
#   - a version carrying a release tag (x.y.z) or a convenience tag (main, latest, x, x.y);
#   - untagged versions: in GHCR they include the per-platform manifests of tagged indexes.
# Environment: GH_TOKEN (packages: write to delete; pull requests and deployments readable) · DRY_RUN (true|false, default
#   true; --delete / --dry-run win) · PR_GRACE_DAYS (7) · RC_KEEP (20) · RC_MIN_AGE_DAYS (30) · CONFIG_DIR
#   (config) · GITHUB_REPOSITORY (owner/repo, for PR lookups).
# Output: one line per version (package, id, tags, age, decision, reason) on stdout and, in CI, a table in
#   $GITHUB_STEP_SUMMARY. Exit codes: 0 ok · 1 an API call failed · 2 usage · 5 mikefarah yq v4 missing.
set -euo pipefail

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

dry_run=${DRY_RUN:-true}
owner=""
repo=${GITHUB_REPOSITORY:-}
packages=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) dry_run=true; shift ;;
    --delete) dry_run=false; shift ;;
    --owner) [[ $# -ge 2 ]] || usage; owner=$2; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || usage; repo=$2; shift 2 ;;
    --package) [[ $# -ge 2 ]] || usage; packages+=("$2"); shift 2 ;;
    -h | --help) usage ;;
    *) echo "retention.sh: unknown argument '$1'" >&2; usage ;;
  esac
done
[[ $dry_run == true || $dry_run == false ]] || { echo "retention.sh: DRY_RUN must be true or false" >&2; exit 2; }
[[ $repo =~ ^[^/]+/[^/]+$ ]] || { echo "retention.sh: --repo owner/repo (or GITHUB_REPOSITORY) is required" >&2; exit 2; }
owner=${owner:-${repo%%/*}}
grace_days=${PR_GRACE_DAYS:-7}
rc_keep=${RC_KEEP:-20}
rc_min_age_days=${RC_MIN_AGE_DAYS:-30}
config_dir=${CONFIG_DIR:-config}
for n in "$grace_days" "$rc_keep" "$rc_min_age_days"; do
  [[ $n =~ ^[0-9]+$ ]] || { echo "retention.sh: PR_GRACE_DAYS, RC_KEEP and RC_MIN_AGE_DAYS must be integers" >&2; exit 2; }
done

# GHCR only (ADR-0032): the sweep works through the GitHub Packages API. Another registry (platform.yml) keeps
# its own retention policy, so the sweep says so and does nothing.
if [[ -f platform.yml ]]; then
  # A plain top-level line, read without yq (ADR-0030 rule 2).
  registry=$(awk '/^registry:/ { sub(/^registry:[ \t]*/, ""); sub(/#.*$/, ""); sub(/[ \t]+$/, ""); print; exit }' platform.yml)
  if [[ -n $registry && ${registry%%/*} != ghcr.io ]]; then
    echo "::notice title=retention::the registry of platform.yml is $registry, not GHCR: retention is the registry's own policy (ADR-0032); nothing to sweep"
    exit 0
  fi
fi

if [[ ${#packages[@]} -eq 0 ]]; then
  # The package is the image path without the registry, <project>/<AppName> (ADR-0010): for a top-level app
  # the project is the release line of platform.yml (:source-database → github-cicd-simple-apps/source-database);
  # a nested app keeps its Gradle parent path (:deephaven-connectors:source-database, in a monorepo).
  project_name=""
  if [[ -f platform.yml ]]; then
    yq --version 2>/dev/null | grep -q mikefarah ||
      { echo "retention.sh: mikefarah yq v4 is needed to read platform.yml (scripts/ci/setup-yq.sh installs it)" >&2; exit 5; }
    project_name=$(yq '.projects[0].name // ""' platform.yml)
  fi
  mapfile -t packages < <(python3 scripts/ci/projects.py --images | jq -r '.[]' | sed 's/^://; s/:/\//g' |
    awk -v project="$project_name" '{ print (project != "" && index($0, "/") == 0) ? project "/" $0 : $0 }')
fi

now=$(date -u +%s)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
api_errors=0 deleted=0 would_delete=0 kept=0

# --- in-use protection ------------------------------------------------------------------------------
declare -A in_use=()
if [[ -d $config_dir ]]; then
  while read -r tag; do
    [[ -n $tag ]] && in_use[$tag]=1
  done < <(
    {
      grep -rhE '^[[:space:]]*IMAGE_TAG=' "$config_dir" --include=_docker-compose.instance.env 2>/dev/null |
        sed -E 's/^[[:space:]]*IMAGE_TAG=["'\'']?([^"'\''[:space:]#]*).*/\1/'
      grep -rhE '^[[:space:]]*tag:[[:space:]]*' "$config_dir" --include=_helm-values.instance.yaml 2>/dev/null |
        sed -E 's/^[[:space:]]*tag:[[:space:]]*["'\'']?([^"'\''[:space:]#]*).*/\1/'
    } | sort -u
  )
fi
# ADR-0027: a dev env's tree declares `main`, so the version it runs is in no file; the last successful GitHub
# Deployment of its Environment (named like the env) names it — the payload's tag and digest-pinned images.
for env_dir in "$config_dir"/*-dev/; do
  [[ -d $env_dir ]] || continue
  env=$(basename "$env_dir")
  while read -r id; do
    [[ -n $id ]] || continue
    state=$(gh api "repos/$repo/deployments/$id/statuses?per_page=1" --jq '.[0].state // empty' 2>/dev/null) || state=""
    [[ $state == success ]] || continue
    while read -r tag; do
      [[ -n $tag ]] && in_use[$tag]=1
    done < <(gh api "repos/$repo/deployments/$id" --jq '.payload | (.tag // empty),
        (.instances[]? | .image // empty | split("@")[0] | split(":") | last),
        (.images[]? | split("@")[0] | split(":") | last)' 2>/dev/null)
    break
  done < <(gh api "repos/$repo/deployments?environment=$env&per_page=20" --jq '.[].id' 2>/dev/null)
done

# --- helpers ----------------------------------------------------------------------------------------
owner_type=$(gh api "users/$owner" --jq .type 2>/dev/null || echo User)
if [[ $owner_type == Organization ]]; then scope="orgs/$owner"; else scope="users/$owner"; fi

declare -A pr_state=()
pr_closed_days() { # prints the days since PR #$1 was closed, or -1 while it is open (or unknown)
  local number=$1 state closed_at
  if [[ -z ${pr_state[$number]+set} ]]; then
    pr_state[$number]=$(gh api "repos/$repo/pulls/$number" --jq '[.state, (.closed_at // "")] | @tsv' 2>/dev/null || echo "unknown")
  fi
  IFS=$'\t' read -r state closed_at <<<"${pr_state[$number]}"
  if [[ $state == closed && -n $closed_at ]]; then
    echo $(((now - $(date -u -d "$closed_at" +%s)) / 86400))
  else
    echo -1
  fi
}

record() { # record <package> <id> <tags> <age-days> <decision> <reason>
  printf '%-45s %-12s %-50s %5sd  %-12s %s\n' "$1" "$2" "$3" "$4" "$5" "$6"
  echo "| \`$1\` | $2 | \`$3\` | $4 d | $5 | $6 |" >> "$summary"
}

delete_version() { # delete_version <package> <encoded package> <id>
  if [[ $dry_run == true ]]; then
    would_delete=$((would_delete + 1))
    return 0
  fi
  if gh api --method DELETE "$scope/packages/container/$2/versions/$3" >/dev/null; then
    deleted=$((deleted + 1))
  else
    echo "retention.sh: deleting $1 version $3 failed" >&2
    api_errors=$((api_errors + 1))
  fi
}

is_protected_tag() {
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || $1 == main || $1 == latest || $1 =~ ^[0-9]+$ || $1 =~ ^[0-9]+\.[0-9]+$ ]]
}

# --- sweep --------------------------------------------------------------------------------------------
{
  echo "### Image retention ($([[ $dry_run == true ]] && echo "dry run — nothing deleted" || echo "deleting"))"
  echo ""
  echo "Rules: \`pr-*\` of PRs closed > ${grace_days} d; keep the ${rc_keep} newest \`-rc.\` and all younger than ${rc_min_age_days} d. In use in \`${config_dir}/\`: ${#in_use[@]} tag(s)."
  echo ""
  echo "| package | version | tags | age | decision | reason |"
  echo "|---|---|---|---|---|---|"
} >> "$summary"

for package in "${packages[@]}"; do
  encoded=${package//\//%2F}
  if ! versions=$(gh api --paginate "$scope/packages/container/$encoded/versions?per_page=100" \
    --jq '.[] | [.id, .created_at, ((.metadata.container.tags // []) | join(","))] | @tsv' 2>/dev/null); then
    echo "retention.sh: package $package not found or not readable — skipped"
    echo "| \`$package\` | — | — | — | skipped | package not found or not readable |" >> "$summary"
    continue
  fi
  rc_candidates=()
  while IFS=$'\t' read -r id created tags; do
    [[ -n $id ]] || continue
    age=$(((now - $(date -u -d "$created" +%s)) / 86400))
    IFS=, read -r -a tag_list <<<"$tags"
    if [[ ${#tag_list[@]} -eq 0 ]]; then
      record "$package" "$id" "-" "$age" keep "untagged (may belong to a tagged index)"; kept=$((kept + 1)); continue
    fi
    reason="" pr_number="" is_rc=false
    for tag in "${tag_list[@]}"; do
      if [[ -n ${in_use[$tag]+set} ]]; then reason="in use in $config_dir/ ($tag)"; break; fi
      if is_protected_tag "$tag"; then reason="release or convenience tag ($tag)"; break; fi
      if [[ $tag =~ ^pr-([0-9]+)-[0-9a-f]{7}$ ]]; then pr_number=${BASH_REMATCH[1]}; fi
      if [[ $tag =~ -rc\.[0-9]+$ ]]; then is_rc=true; fi
    done
    if [[ -n $reason ]]; then
      record "$package" "$id" "$tags" "$age" keep "$reason"; kept=$((kept + 1))
    elif [[ -n $pr_number ]]; then
      closed=$(pr_closed_days "$pr_number")
      if ((closed > grace_days)); then
        record "$package" "$id" "$tags" "$age" "$([[ $dry_run == true ]] && echo would-delete || echo delete)" "PR #$pr_number closed $closed d ago"
        delete_version "$package" "$encoded" "$id"
      else
        record "$package" "$id" "$tags" "$age" keep "PR #$pr_number open or closed ≤ ${grace_days} d"; kept=$((kept + 1))
      fi
    elif $is_rc; then
      rc_candidates+=("$created"$'\t'"$id"$'\t'"$tags"$'\t'"$age")
    else
      record "$package" "$id" "$tags" "$age" keep "no retention rule"; kept=$((kept + 1))
    fi
  done <<<"$versions"

  # Pre-releases, newest first: keep RC_KEEP, and anything younger than RC_MIN_AGE_DAYS.
  rank=0
  while IFS=$'\t' read -r created id tags age; do
    [[ -n $id ]] || continue
    rank=$((rank + 1))
    if ((rank <= rc_keep)); then
      record "$package" "$id" "$tags" "$age" keep "pre-release #$rank of the newest $rc_keep"; kept=$((kept + 1))
    elif ((age < rc_min_age_days)); then
      record "$package" "$id" "$tags" "$age" keep "pre-release younger than $rc_min_age_days d"; kept=$((kept + 1))
    else
      record "$package" "$id" "$tags" "$age" "$([[ $dry_run == true ]] && echo would-delete || echo delete)" "pre-release #$rank, older than $rc_min_age_days d"
      delete_version "$package" "$encoded" "$id"
    fi
  done < <(printf '%s\n' ${rc_candidates[@]+"${rc_candidates[@]}"} | sort -r)
done

result="kept $kept, $([[ $dry_run == true ]] && echo "would delete $would_delete" || echo "deleted $deleted"), API errors $api_errors"
echo "retention.sh: $result"
printf '\n%s\n' "$result" >> "$summary"
((api_errors == 0)) || exit 1
