#!/usr/bin/env bash
set -euo pipefail

# Use the release workflow's reviewed pin, so dependency updates have one owner.
source_root=$(git rev-parse --show-toplevel)
mapfile -t pins < <(sed -nE 's/^[[:space:]]*uses: BigWigsMods\/packager@([0-9a-f]{40})[[:space:]]*$/\1/p' "$source_root/.github/workflows/release.yml" | sort -u)
if [[ ${#pins[@]} != 1 ]]; then
  echo 'Expected one consistent pinned Packager revision in release.yml.' >&2
  exit 1
fi
if [[ $# -gt 1 || ( $# == 1 && $1 != --self-test ) ]]; then
  echo 'Usage: build-check-package.sh [--self-test]' >&2
  exit 1
fi

scratch_parent=$(cd -- "${RUNNER_TEMP:-${TMPDIR:-/tmp}}" && pwd -P)
scratch=$(mktemp -d "$scratch_parent/statspro-check-package.XXXXXXXX")
cleanup() {
  [[ -d $scratch ]] || return 0
  if [[ $scratch != "$scratch_parent"/statspro-check-package.* || -L $scratch ||
        $(cd -- "$scratch" && pwd -P) != "$scratch" ]]; then
    echo 'Refusing cleanup outside the owned temporary directory.' >&2
    return 1
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT
packager="$scratch/packager"
git init --quiet "$packager"
git -C "$packager" fetch --quiet --depth=1 https://github.com/BigWigsMods/packager.git "${pins[0]}"
git -C "$packager" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
if [[ $(git -C "$packager" rev-parse HEAD) != "${pins[0]}" ]]; then
  echo 'Packager checkout does not match the reviewed revision.' >&2
  exit 1
fi

build_package() {
  # WHY: Packager suppresses branch pushes when a tag already names HEAD, even
  # with -d. Checks must build those commits too. Only this child loses the CI
  # duplicate-publish heuristic; -d keeps all uploads disabled.
  env -u GITHUB_ACTIONS bash "$packager/release.sh" -d -t "$1" -r "$2"
  local archives=("$2"/StatsPro-*.zip)
  if [[ ${#archives[@]} != 1 || ! -s ${archives[0]} ]]; then
    echo 'Packager did not produce exactly one nonempty StatsPro archive.' >&2
    return 1
  fi
}

if [[ ${1:-} == --self-test ]]; then
  fixture="$scratch/source"
  git clone --quiet --no-hardlinks "$source_root" "$fixture"
  # All mutations are confined to this disposable clone, never the source refs.
  git -C "$fixture" -c tag.gpgSign=false tag v2147483647.0.0
  log="$scratch/suppressed.log"
  env GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
    bash "$packager/release.sh" -d -t "$fixture" -r "$scratch/suppressed" > "$log" 2>&1
  if ! grep -q 'Found future tag' "$log" || [[ -d "$scratch/suppressed" ]]; then
    echo 'Tagged-push fixture did not reproduce the upstream no-package exit.' >&2
    exit 1
  fi
  export GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main
  build_package "$fixture" "$scratch/tagged"
  git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgSign=false -c core.hooksPath=/dev/null commit --quiet --allow-empty -m 'Fixture descendant'
  build_package "$fixture" "$scratch/untagged"
  git -C "$fixture" -c advice.detachedHead=false checkout --quiet --detach HEAD
  export GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge
  build_package "$fixture" "$scratch/pull-request"
  [[ $GITHUB_ACTIONS == true && $GITHUB_EVENT_NAME == pull_request ]]
  echo 'Packager tagged-push, untagged-push, and pull-request regressions passed.'
else
  build_package "$source_root" "$source_root/.release"
fi
