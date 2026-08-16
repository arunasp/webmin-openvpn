#!/bin/bash
# Words that keep appearing and should not.
#
# "real" is the one that prompted this. It arrives as emphasis - a real
# server, a real Webmin, the real tool - and it never carries information:
# the sentence is about a server, or about Webmin, or about easy-rsa, and
# naming the thing is both shorter and more precise. Prose that reaches for
# emphasis instead of specifics reads as generated, and it crept back in
# repeatedly, so it is checked rather than remembered.
#
# The others are the same failure in different clothes: filler that survives
# because it sounds like conviction.
#
# Technical terms that happen to contain a listed word are exempt by exact
# phrase below, not by weakening the rule. RLIMIT_NPROC really is defined per
# real UID, and OpenVPN's status file really does have a Real Address column;
# those are names, not emphasis.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

cd "$repo" || exit 1

# One word per line, matched whole and case-insensitively.
# Words with no technical use here: every one of them is emphasis standing
# in for a specific noun. Judgement words that do carry meaning -
# deliberately, actually, cleanly - are left alone; the fix for those is
# writing less of them, not a check.
BANNED='real
really
genuinely
seamlessly
seamless
robustly
effortlessly
surely
obviously
essentially
fundamentally
crucially
delve
showcase
plethora
myriad
leverage
utilize'

# Exact phrases where a banned word is part of a name defined elsewhere.
EXEMPT='real UID
Real Address
real_address'

files=$(git ls-files | grep -vE '^openvpn/|\.wbm\.gz$|^tests/style\.sh$')

found=0
for word in $BANNED; do
    hits=$(printf '%s\n' "$files" | xargs grep -inw "$word" 2>/dev/null || true)
    [ -n "$hits" ] || continue
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        exempt=0
        while IFS= read -r phrase; do
            [ -n "$phrase" ] || continue
            case "$hit" in
                *"$phrase"*) exempt=1; break ;;
            esac
        done <<< "$EXEMPT"
        if [ "$exempt" -eq 0 ]; then
            found=$((found + 1))
            printf '  %s\n' "$hit"
        fi
    done <<< "$hits"
done

if [ "$found" -eq 0 ]; then
    pass "no filler words outside the exempt technical terms"
else
    fail "no filler words" "$found occurrence(s) above - name the thing instead"
fi

# An em dash among ASCII hyphens is the other half of the same habit: the
# tree uses " - " everywhere, and a stray em dash marks text that came from
# somewhere with different typographic manners.
dashes=$(printf '%s\n' "$files" | xargs grep -n '—' 2>/dev/null || true)
if [ -z "$dashes" ]; then
    pass "no em dashes; the tree uses ASCII hyphens"
else
    fail "no em dashes" "$(printf '%s' "$dashes" | head -3 | tr '\n' ' ')"
fi

report
