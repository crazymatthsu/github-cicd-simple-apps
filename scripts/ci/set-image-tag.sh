#!/usr/bin/env bash
# set-image-tag.sh — set the image tag in AppInstance config files (ADR-0029).
#
# Usage: set-image-tag.sh <tag> <file>...
#   _docker-compose.instance.env  IMAGE_TAG=<tag>  (the line is replaced in place, or appended when missing)
#   _helm-values.instance.yaml    .image.tag       (only when the file already has an `image` mapping — ADR-0019;
#                                                   needs mikefarah yq v4, as on GitHub-hosted runners)
#   (the instance layers of ADR-0012: the only ones that hold the tag)
# Prints each file whose content changed. Touches nothing else in the files.
# Exit codes: 0 ok (also when nothing changed) · 2 usage · 4 file missing or of an unsupported kind.
set -euo pipefail

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
tag=$1
shift
# Docker tag grammar; floating-tag policy per env is config-lint's job (ADR-0014 check 10).
[[ $tag =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo "set-image-tag.sh: invalid tag '$tag'" >&2; exit 2; }

for file in "$@"; do
  [[ -f $file ]] || { echo "set-image-tag.sh: $file not found" >&2; exit 4; }
  tmp=$(mktemp)
  case "$(basename "$file")" in
    _docker-compose.instance.env)
      awk -v tag="$tag" '
        /^IMAGE_TAG=/ { if (!done) { print "IMAGE_TAG=" tag; done = 1 }; next }
        { print }
        END { if (!done) print "IMAGE_TAG=" tag }
      ' "$file" > "$tmp"
      ;;
    _helm-values.instance.yaml)
      cp "$file" "$tmp"
      if [[ $(yq '.image | tag' "$file") == '!!map' ]]; then
        TAG="$tag" yq -i '.image.tag = strenv(TAG)' "$tmp"
      fi
      ;;
    *)
      rm -f "$tmp"
      echo "set-image-tag.sh: unsupported file $file (expected _docker-compose.instance.env or _helm-values.instance.yaml)" >&2
      exit 4
      ;;
  esac
  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
  else
    cat "$tmp" > "$file" # keeps the file's mode and ownership
    rm -f "$tmp"
    echo "$file"
  fi
done
