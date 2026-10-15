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
  local package_source=$1
  local output_root=$2
  local beta_tags=()
  mapfile -t beta_tags < <(git -C "$package_source" tag --list 'forever-*')
  if (( ${#beta_tags[@]} )); then
    # Upstream describes every tag. Hide this independent channel only in a
    # disposable exact-HEAD clone, preserving the user's source refs and work.
    if [[ -n $(git -C "$package_source" status --porcelain --untracked-files=no) ]]; then
      echo 'Forever-tag isolation requires clean tracked package sources.' >&2
      return 1
    fi
    local source_commit isolated
    source_commit=$(git -C "$package_source" rev-parse --verify HEAD)
    isolated=$(mktemp -d "$scratch/build-source.XXXXXXXX")
    git clone --quiet --no-hardlinks --no-checkout "$package_source" "$isolated"
    if [[ $isolated != "$scratch"/build-source.* || -L $isolated ||
          $(cd -- "$isolated/.git" && pwd -P) != "$isolated/.git" ]]; then
      echo 'Refusing tag isolation outside the owned scratch clone.' >&2
      return 1
    fi
    git -C "$isolated" -c advice.detachedHead=false checkout --quiet --detach "$source_commit"
    for beta_tag in "${beta_tags[@]}"; do
      git -C "$isolated" update-ref -d "refs/tags/$beta_tag"
    done
    [[ $(git -C "$isolated" rev-parse HEAD) == "$source_commit" ]]
    package_source=$isolated
  fi
  # WHY: Packager suppresses branch pushes when a tag already names HEAD, even
  # with -d. Checks must build those commits too. Only this child loses the CI
  # duplicate-publish heuristic; -d keeps all uploads disabled.
  env -u GITHUB_ACTIONS bash "$packager/release.sh" -d -t "$package_source" -r "$output_root"
  local archives=("$output_root"/StatsPro-*.zip)
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
  git -C "$fixture" -c tag.gpgSign=false tag forever-v2147483647.0.1
  export GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main
  build_package "$fixture" "$scratch/tagged"
  [[ -s "$scratch/tagged/StatsPro-v2147483647.0.0.zip" ]]
  git -C "$fixture" rev-parse --verify refs/tags/forever-v2147483647.0.1 >/dev/null
  git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgSign=false -c core.hooksPath=/dev/null commit --quiet --allow-empty -m 'Fixture descendant'
  git -C "$fixture" -c tag.gpgSign=false tag forever-v2147483647.0.2
  build_package "$fixture" "$scratch/untagged"
  descendant_archives=("$scratch/untagged"/StatsPro-v2147483647.0.0-1-g*.zip)
  [[ ${#descendant_archives[@]} == 1 && -s ${descendant_archives[0]} ]]
  git -C "$fixture" rev-parse --verify refs/tags/forever-v2147483647.0.2 >/dev/null
  printf '\nFixture dirty tracked source\n' >> "$fixture/README.md"
  if build_package "$fixture" "$scratch/dirty" > "$scratch/dirty.log" 2>&1; then
    echo 'Forever isolation silently discarded dirty tracked sources.' >&2
    exit 1
  fi
  grep -q 'requires clean tracked package sources' "$scratch/dirty.log"
  git -C "$fixture" show HEAD:README.md > "$fixture/README.md"
  git -C "$fixture" -c advice.detachedHead=false checkout --quiet --detach HEAD
  export GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge
  build_package "$fixture" "$scratch/pull-request"
  [[ $GITHUB_ACTIONS == true && $GITHUB_EVENT_NAME == pull_request ]]
  echo 'Packager tagged-push, Forever HEAD/descendant isolation, dirty-source rejection, and pull-request regressions passed.'
else
  build_package "$source_root" "$source_root/.release"
fi
