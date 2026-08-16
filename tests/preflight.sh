#!/bin/bash
# Everything that has to be true before this branch is pushed to a public
# repository.
#
# make scan checks the working tree. A push publishes every commit, and this
# repository has already had to be rebuilt twice because a leak sat in history
# while the tip was clean - first a live hostname, then a site codename in a
# module name. Rewriting is free only while nothing has been pushed, so this
# is the last point at which either is cheap to fix.
#
# Each unpushed commit is extracted and scanned with the same rules as the
# working tree, because a rule applied to one tree and not the others is not
# a rule.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
base=${BASE:-origin/main}
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
echo "== one commit per change"
# A branch is read as history once it is pushed, and rewriting it after that
# costs everyone who has fetched it. Before the push it costs nothing, so the
# tidying happens here: a commit that fixes one already on the branch belongs
# inside it, not after it.
#
# Two shapes are mechanical. A message marked as a fixup was never meant to
# survive. And several commits sharing a subject scope - the text before the
# colon - are usually one change told in instalments, which is a note rather
# than a failure, because a scope can legitimately change twice in a branch.
wip=$(git log --format='%h %s' "${range[@]}" |
      grep -iE '^[0-9a-f]+ (fixup!|squash!|wip[: ]|tmp[: ]|amend[: ])' || true)
if [ -z "$wip" ]; then
    pass "no fixup, squash or wip commits"
else
    fail "no fixup, squash or wip commits" "$(printf '%s' "$wip" | tr '\n' ' ')"
fi

dupes=$(git log --format=%s "${range[@]}" | sed -n 's/^\([a-z0-9-]*\):.*/\1/p' |
        sort | uniq -d | tr '\n' ' ')
if [ -z "$dupes" ]; then
    pass "each subject scope appears once"
else
    echo "[note] more than one commit under: $dupes"
    echo "       squash them if they are one change told in instalments"
fi

echo
echo "== behaviour and its prose"
# Not an assertion. Plenty of changes to these paths need no documentation at
# all - a test fix, a comment, an internal rename - and a rule that failed on
# them would be argued with once and skipped thereafter.
#
# What make docs already enforces are the facts that can be compared:
# subcommands, settings, make targets, module defaults, pinned versions. This
# covers the remainder, where a behaviour changed and the sentence describing
# it lives somewhere no check can reach.
behaviour=$(git diff --name-only "${range[@]}" -- tools openvpn-server packaging \
            .github Makefile 2>/dev/null | head -20)
prose=$(git diff --name-only "${range[@]}" -- '*.md' 2>/dev/null | head -20)
if [ -n "$behaviour" ] && [ -z "$prose" ]; then
    echo "[note] these commits change behaviour and touch no document:"
    printf '%s\n' "$behaviour" | sed 's/^/         /'
    echo "       If any of it changed what the software does, the sections"
    echo "       describing that behaviour are the ones to re-read."
elif [ -n "$behaviour" ]; then
    pass "behaviour and documentation both changed"
else
    pass "no behaviour changed"
fi

echo
echo "== commit messages"
# The same scanner, applied to the messages. Naming providers in a denylist
# here would have put the very strings this is meant to keep out into a file
# that gets published - so the messages are written where the structural rules
# already look, and checked with those.
mkdir -p "$tmp/messages/docs"
git log --format='%H %B' "${range[@]}" > "$tmp/messages/docs/commit-messages.md" 2>/dev/null
if python3 "$here/scan.py" "$tmp/messages" > "$tmp/msgout" 2>&1; then
    pass "no host name, address or local path in any commit message"
else
    fail "no host name, address or local path in any commit message" \
         "$(sed -n '2,6p' "$tmp/msgout" | tr '\n' ' ')"
fi

echo
echo "== what would be published"
printf '  %s files, %s commits, %s\n' \
    "$(git ls-tree -r --name-only HEAD | wc -l)" \
    "$(printf '%s\n' "$commits" | wc -l)" \
    "$(git log -1 --format='%h %s' HEAD)"

report
