#!/bin/bash
# Facts the documentation states that the tree can contradict.
#
# Documentation goes stale silently. Nothing errors, nothing fails to build,
# and the first sign is somebody following an instruction that no longer
# works. The Makefile, the module configuration and the pinned dependency
# refs are the sources of truth for what the docs describe, so the docs are
# checked against them here.
#
# This checks facts, not prose. It cannot tell whether an explanation is
# still true, only whether a target, a setting, a version or a link still
# refers to something that exists.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
module=${MODULE:-openvpn-server}
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

cd "$repo" || exit 1

docs=(README.md CONTRIBUTING.md DEPLOY.md docs/clients.md docs/design.md)

echo "== every make target the docs mention exists"
targets=$(grep -hoE '^[a-z0-9-]+:' Makefile cicd-common.mk | tr -d ':' | sort -u)
# Only where make is invoked: a sentence about "a make target" is prose.
# A command, not a mention: line start, inside a fenced block, indented in a
# code block, or in backticks. 'Every check is a make target' is prose.
mentioned=$(grep -ohE '(^|`|    )make [a-z0-9-]+' "${docs[@]}" | awk '{print $NF}' | sort -u)
missing=
for t in $mentioned; do
    printf '%s\n' "$targets" | grep -qx "$t" || missing="$missing $t"
done
if [ -z "$missing" ]; then
    pass "all documented make targets exist ($(printf '%s\n' "$mentioned" | wc -l) referenced)"
else
    fail "all documented make targets exist" "not in the Makefile:$missing"
fi

echo
echo "== the module settings table matches the module's own defaults"
# README documents each setting and its default. The config file is what
# Webmin installs, so it decides.
# The key and its default have to be on one line: a table row. Accepting
# them anywhere in the file passes on a table that has lost the row, as
# long as the value appears in some paragraph.
while IFS='=' read -r key value; do
    [ -n "$key" ] || continue
    if grep -qE "^\|.*\`$key\`.*\`$value\`.*\|" README.md; then
        pass "$key is a row in the settings table, with its default"
    else
        fail "$key is a row in the settings table, with its default" \
             "expected a row naming $key and $value"
    fi
done < "$module/config"

echo
echo "== every stage all and lint compose is in the stage table"
# This is the check that a prose summary cannot survive: a target gains a
# prerequisite and every sentence listing what it does becomes wrong without
# anything failing. The table in CONTRIBUTING is the enumeration, so it has
# to be complete.
stages=$(sed -n 's/^all: *//p;s/^lint: *//p' Makefile |
         sed 's/#.*//' | tr ' ' '\n' | sort -u | grep -v '^$')
undocumented=
for stage in $stages; do
    if grep -qE '^\\| `'"$stage"'`' CONTRIBUTING.md; then
        :
    else
        undocumented="$undocumented $stage"
    fi
done
if [ -z "$undocumented" ]; then
    pass "the stage table covers everything all and lint run"
else
    fail "the stage table covers everything all and lint run" \
         "missing from the table:$undocumented"
fi

echo
echo "== pinned versions in the docs match the Makefile"
webmin_ref=$(sed -n 's/^WEBMIN_REF *?*= *//p' Makefile | head -1 | tr -d ' ')
easyrsa_refs=$(sed -n 's/^EASYRSA_REFS *?*= *//p' Makefile | head -1)
for ref in $webmin_ref; do
    if grep -qF "$ref" "${docs[@]}"; then
        pass "Webmin $ref is the version the docs name"
    else
        fail "Webmin $ref is the version the docs name" \
             "the Makefile pins $ref; the docs say something else"
    fi
done
for ref in $easyrsa_refs; do
    stripped=${ref#v}
    major_minor=${stripped%.*}
    if grep -qF "$major_minor" "${docs[@]}"; then
        pass "easy-rsa $stripped is covered by the docs"
    else
        echo "[note] the docs do not mention easy-rsa $stripped, which e2e tests"
    fi
done

echo
echo "== a release example is a placeholder, not a version that will age"
# A concrete version in an example is wrong the moment the next one ships,
# and it is the kind of wrong nobody notices because it still looks right.
concrete=$(grep -nE 'v[0-9]+\.[0-9]+\.[0-9]+' "${docs[@]}" |
           grep -vE 'X\.Y\.Z|vX\.Y\.Z' || true)
if [ -z "$concrete" ]; then
    pass "release examples use a placeholder"
else
    fail "release examples use a placeholder" \
         "$(printf '%s' "$concrete" | head -3 | tr '\n' ' ')"
fi

echo
echo "== internal links resolve"
broken=
for l in $(grep -ohE '\]\([^)h][^)]*\)' "${docs[@]}" | tr -d '()]' | sed 's/#.*//' | sort -u); do
    [ -n "$l" ] || continue
    t=$l
    case $l in ../*) t=${l#../} ;; esac
    [ -e "$t" ] || broken="$broken $l"
done
if [ -z "$broken" ]; then
    pass "every internal link points at a file that exists"
else
    fail "every internal link points at a file that exists" "$broken"
fi

report
