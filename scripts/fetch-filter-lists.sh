#!/usr/bin/env bash
# Downloads every filter list in the shields catalog, plus Brave's scriptlet
# resources, so a release ships with working lists before the first daily update.
#
# Usage: scripts/fetch-filter-lists.sh <catalog.json> <out-dir>
#   <out-dir>/<id>.txt       one file per catalog entry
#   <out-dir>/resources.json Brave adblock-resources (scriptlets, redirect resources)
set -euo pipefail

resources_url="https://raw.githubusercontent.com/brave/adblock-resources/master/dist/resources.json"

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <catalog.json> <out-dir>" >&2
  exit 2
fi
catalog="$1"
out="$2"

mkdir -p "$out"

# Servers sometimes answer 200 with an error page, which adblock-rust would
# parse as a list of nonsense rules.
fetch() {
  local url="$1" dest="$2"
  curl --fail --silent --show-error --location --retry 3 --max-time 120 --output "$dest" "$url"
  if [[ ! -s "$dest" ]]; then
    echo "error: $url returned an empty body" >&2
    exit 1
  fi
  if head -c 1024 "$dest" | grep -qiE '<!doctype html|<html'; then
    echo "error: $url returned HTML instead of a filter list" >&2
    exit 1
  fi
}

count=0
while IFS=$'\t' read -r id url; do
  if [[ ! "$id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "error: catalog id '$id' is not a safe file name" >&2
    exit 1
  fi
  echo "fetching $id"
  fetch "$url" "$out/$id.txt"
  count=$((count + 1))
done < <(jq -r '.[] | [.id, .url] | @tsv' "$catalog")

if [[ $count -eq 0 ]]; then
  echo "error: $catalog contains no lists" >&2
  exit 1
fi

echo "fetching resources.json"
fetch "$resources_url" "$out/resources.json"
jq -e . "$out/resources.json" >/dev/null
echo "fetched $count lists into $out"
