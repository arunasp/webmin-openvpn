#!/bin/bash
# Assertions about the built module package.
#
# build produces a tarball; without this, "build succeeded" only means tar
# exited zero. These are the failures that would otherwise be discovered by
# installing a broken module on the bastion:
#
#   - a missing file, so Webmin shows an empty or erroring page
#   - a wrong category, so the module does not appear under Servers
#   - key material swept into the package by a stray file in the module dir
#   - a $text{...} key with no entry in lang/en, which renders as an empty
#     string in the UI and is invisible until someone reads that page.
#     Webmin's global language file also supplies keys, and this check does
#     not know about them: the module defines everything it uses, which keeps
#     the assertion strict and the module independent of Webmin's own strings
set -uo pipefail

package=${1:?usage: verify-package.sh <package.wbm.gz>}
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
module=${MODULE:-openvpn-server}
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

if [ ! -f "$package" ]; then
    fail "package exists" "$package not found"
    report
    exit 1
fi

listing=$(tar -tzf "$package")

echo "== contents"
for want in module.info config.info config lang/en openvpn-server-lib.pl index.cgi install_check.pl; do
    case "$listing" in
        *"$module/$want"*) pass "package contains $want" ;;
        *) fail "package contains $want" "not in $package" ;;
    esac
done

echo
echo "== nothing that should never be packaged"
secrets=$(printf '%s\n' "$listing" |
          grep -E '\.(key|crt|pem|ovpn|p12|pfx)$' || true)
if [ -z "$secrets" ]; then
    pass "no key material in the package"
else
    fail "no key material in the package" "$secrets"
fi

echo
echo "== module.info"
info=$(tar -xzOf "$package" "$module/module.info")
assert_contains "category is servers" "$info" "category=servers"
assert_contains "declares a name" "$info" "name="
assert_contains "declares a version" "$info" "version="
assert_contains "declares a long description" "$info" "longdesc="

echo
echo "== every string used is a string defined"
# Keys the code asks for, via $text{'key'} and &text('key', ...).
# shellcheck disable=SC2016  # the $text is Perl's, not this shell's
pattern='\$text\{'"'"'[a-z0-9_]+'"'"'\}|&text\('"'"'[a-z0-9_]+'"'"''
used=$(grep -rhoE "$pattern" "$repo/$module" |
       grep -oE "'[a-z0-9_]+'" | tr -d "'" | sort -u)
defined=$(grep -oE '^[a-z0-9_]+=' "$repo/$module/lang/en" | tr -d '=' | sort -u)
missing=$(comm -23 <(printf '%s\n' "$used") <(printf '%s\n' "$defined"))
if [ -z "$missing" ]; then
    pass "all $(printf '%s\n' "$used" | wc -l) referenced strings are defined"
else
    fail "every referenced string is defined" "missing from lang/en: $(printf '%s' "$missing" | tr '\n' ' ')"
fi

# The reverse is a warning, not a failure: an unused string is harmless, and
# translations legitimately carry keys ahead of the code that uses them.
unused=$(comm -13 <(printf '%s\n' "$used") <(printf '%s\n' "$defined"))
if [ -n "$unused" ]; then
    echo "[note] defined but unused: $(printf '%s' "$unused" | tr '\n' ' ')"
fi

report
