#!/bin/bash
# Everything that has to be true before this branch is pushed to a public
# repository.
#
# make scan checks the working tree. A push publishes every commit, and this
# repository has already had to be rebuilt twice because a leak sat in history
# while the tip was clean - first a real hostname, then a site codename in a
# module name. Rewriting is free only while nothing has been pushed, so this
# is the last point at which either is cheap to fix.
#
# Each unpushed commit is extracted and scanned with the same rules as the
# working tree, because a rule applied to one tree and not the others is not
# a rule.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
base=${BASE:-origin/master}
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

cd "$repo" || exit 1

echo "== working tree"
dirty=$(git status --porcelain)
if [ -z "$dirty" ]; then
    pass "no uncommitted changes"
else
    fail "no uncommitted changes" "$(printf '%s' "$dirty" | tr '\n' ' ')"
fi

# Caches are large and some contain third-party source; none of it belongs in
# a commit.
staged_junk=$(git ls-files | grep -E '^(local|\.cpanm|\.easyrsa|\.webmin|build)/' || true)
if [ -z "$staged_junk" ]; then
    pass "no cache or build output is tracked"
else
    fail "no cache or build output is tracked" "$staged_junk"
fi

echo
echo "== the working tree"
if python3 "$here/scan.py" "$repo" >/dev/null 2>&1; then
    pass "leak scan is clean"
else
    fail "leak scan is clean" "run 'make scan' for the findings"
fi

echo
echo "== every commit this push would publish"
# An array, so the two-argument form needs no quoting exception.
if git rev-parse --verify "$base" >/dev/null 2>&1; then
    range=(HEAD "^$base")
else
    echo "[note] $base does not exist here; checking all commits on HEAD"
    range=(HEAD)
fi

commits=$(git rev-list "${range[@]}")
if [ -z "$commits" ]; then
    fail "there is something to push" "no commits ahead of $base"
    report
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
clean=1
for c in $commits; do
    rm -rf "${tmp:?}/tree"
    mkdir -p "$tmp/tree"
    # Commit dates can sit ahead of a container clock; that warning is not a
    # finding and would bury the ones that are.
    git archive "$c" | tar -x --warning=no-timestamp -C "$tmp/tree"
    if python3 "$here/scan.py" "$tmp/tree" > "$tmp/out" 2>&1; then
        printf '  %s  clean\n' "$(git log -1 --format=%h "$c")"
    else
        clean=0
        printf '  %s  LEAK\n' "$(git log -1 --format=%h "$c")"
        sed -n '2,8p' "$tmp/out"
    fi
done
if [ "$clean" -eq 1 ]; then
    pass "$(printf '%s\n' "$commits" | wc -l) commits scanned, none leaking"
else
    fail "every commit is clean" "rebuild the branch before pushing; see CONTRIBUTING.md"
fi

echo
echo "== commit messages"
# The scanner reads files, not messages, and a message is published too.
messages=$(git log --format='%H %B' "${range[@]}" 2>/dev/null)
# \134 is the octal escape for a backslash. Written this way because a literal
# backslash next to a closing quote is ambiguous to read and to lint.
winpath=$(printf ':\134')
msgleak=$(printf '%s\n' "$messages" |
          grep -niE '[a-z0-9-]+\.(gleeze|dynu|ddns|duckdns)\.[a-z]+' || true)
msgleak="$msgleak$(printf '%s\n' "$messages" | grep -nF "$winpath" || true)"
if [ -z "$msgleak" ]; then
    pass "no obvious site identity in commit messages"
else
    fail "no obvious site identity in commit messages" "$msgleak"
fi

echo
echo "== what would be published"
printf '  %s files, %s commits, %s\n' \
    "$(git ls-tree -r --name-only HEAD | wc -l)" \
    "$(printf '%s\n' "$commits" | wc -l)" \
    "$(git log -1 --format='%h %s' HEAD)"

report
