#!/bin/bash
# Tests scripts/clothod-dist.sh against fake clothod checkouts: the user's app bundles only a
# released dist, and refuses dev dists and unreleased versions. Runs anywhere (no Xcode, no builds).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
pick=$here/clothod-dist.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/clt-distcheck.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM
passed=0 failed=0

# fake <dir> <cargo version> <released or "-"> : a clothod checkout with no dists.
fake() {
  mkdir -p "$1"
  printf '[workspace.package]\nversion = "%s"\n' "$2" > "$1/Cargo.toml"
  [[ "$3" == - ]] || echo "$3" > "$1/RELEASED"
}
# dist <dir> <version> [id version] : a dist with two builds.
dist() {
  local id=${3:-$2}
  mkdir -p "$1/macos-aarch64" "$1/linux-x86_64"
  touch "$1/macos-aarch64/clothod" "$1/linux-x86_64/clothod"
  cat > "$1/manifest.json" <<JSON
{
  "version": "$2",
  "builds": {
    "macos-aarch64": {"target": "aarch64-apple-darwin", "id": "$id-aaaaaaaaaaaa", "size": 1, "file": "macos-aarch64/clothod"},
    "linux-x86_64": {"target": "x86_64-unknown-linux-musl", "id": "$id-bbbbbbbbbbbb", "size": 1, "file": "linux-x86_64/clothod"}
  }
}
JSON
}
# expect ok|fail <name> <root> [CLOTHOD_DIST] [mode] ; with ok, the dist chosen must end in $EXPECT.
expect() {
  local want=$1 name=$2 root=$3 override=${4:-} mode=${5:-} out status
  out=$(CLOTHOD_ROOT=$root CLOTHOD_DIST=$override "$pick" $mode 2>"$tmp/err"); status=$?
  if [[ "$want" == ok && $status -eq 0 && "$out" == *"$EXPECT" ]] || [[ "$want" == fail && $status -ne 0 && -z "$out" ]]; then
    passed=$((passed + 1)); echo "ok   $name"
  else
    failed=$((failed + 1)); echo "FAIL $name (status $status, out '$out')"; sed 's/^/     /' "$tmp/err"
  fi
}

# Released 0.1.12, its dist in place; Cargo already bumped to 0.1.13 for the next release.
r=$tmp/released; fake $r 0.1.13 0.1.12; dist $r/dist 0.1.12
EXPECT=/released/dist expect ok "released dist is bundled" $r
EXPECT=/released/dist expect ok "--check reports it" $r "" --check
grep -q "0.1.12-aaaaaaaaaaaa" "$tmp/err" && { passed=$((passed + 1)); echo "ok   --check lists the build ids"; } \
  || { failed=$((failed + 1)); echo "FAIL --check lists the build ids"; }

# The incident: only a dev dist of an unreleased version, and dist/ holds an unrecorded build.
d=$tmp/devonly; fake $d 0.1.11 0.1.10; dist $d/target/dist-dev 0.1.11; dist $d/dist 0.1.11
expect fail "unreleased version in dist/ is refused" $d
expect fail "dist-dev named by CLOTHOD_DIST is refused" $d $d/target/dist-dev
ln -s $d/target/dist-dev $tmp/innocent-name
expect fail "dist-dev through a symlink is refused" $d $tmp/innocent-name
mkdir -p $tmp/elsewhere; dist $tmp/elsewhere/dist-dev 0.1.10
expect fail "any dir called dist-dev is refused" $d $tmp/elsewhere/dist-dev

# Other ways a dist can be wrong.
n=$tmp/nodist; fake $n 0.1.12 0.1.12
expect fail "no dist at all is refused (never built here)" $n
[[ ! -e $n/dist ]] && { passed=$((passed + 1)); echo "ok   nothing was built"; } || { failed=$((failed + 1)); echo "FAIL a dist was built"; }
u=$tmp/unreleased; fake $u 0.1.12 -; dist $u/dist 0.1.12
expect fail "no RELEASED is refused" $u
m=$tmp/mixed; fake $m 0.1.12 0.1.12; dist $m/dist 0.1.12 0.1.11
expect fail "build ids of another version are refused" $m
g=$tmp/gap; fake $g 0.1.12 0.1.12; dist $g/dist 0.1.12; rm $g/dist/linux-x86_64/clothod
expect fail "a missing build is refused" $g

# Clotho Dev: the released dist when it is for the current version; CLOTHOD_DIST as given.
c=$tmp/current; fake $c 0.1.12 0.1.12; dist $c/dist 0.1.12
EXPECT=/current/dist expect ok "--dev uses the current release" $c "" --dev
EXPECT=/devonly/target/dist-dev expect ok "--dev may use dist-dev" $d $d/target/dist-dev --dev

echo "$passed passed, $failed failed"
[[ $failed -eq 0 ]]
