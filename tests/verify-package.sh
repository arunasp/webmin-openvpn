#!/bin/bash
# Assertions about the built module package.
#
# build produces a tarball; without this, "build succeeded" only means tar
# exited zero. These are the failures that would otherwise be discovered by
# installing a broken module on a server:
#
#   - a missing file, so Webmin shows an empty or erroring page
#   - a wrong category, so the module does not appear under Servers
#   - key material swept into the package by a stray file in the module dir
#   - a package Webmin's own installer would reject, checked against what
#     install_webmin_module actually does: gzip magic, a listable tar, every
#     top-level entry a directory carrying module.info, and a parseable
#     depends line
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

# What Webmin checks before it will unpack anything. install_webmin_module
# reads the first two bytes to pick a decompressor, runs tar tf, then insists
# every top-level directory contains module.info or theme.info.
echo "== what Webmin's installer requires"
magic=$(od -An -tx1 -N2 "$package" | tr -d ' ')
assert_eq "gzip magic, so Webmin picks gunzip" "1f8b" "$magic"

if tar -tf "$package" >/dev/null 2>&1; then
    pass "tar can list the archive"
else
    fail "tar can list the archive" "tar tf failed"
fi

tops=$(printf '%s\n' "$listing" | sed 's|^\./||; s|/.*||' | sort -u | grep -v '^$')
assert_eq "exactly one top-level directory" "$module" "$tops"

case "$listing" in
    *"$module/module.info"*) pass "that directory carries module.info" ;;
    *) fail "that directory carries module.info" "installer rejects the package without it" ;;
esac

# An absolute or traversing path would unpack outside the module directory.
escapes=$(printf '%s\n' "$listing" | grep -E '^/|(^|/)\.\./' || true)
if [ -z "$escapes" ]; then
    pass "no absolute or traversing paths"
else
    fail "no absolute or traversing paths" "$escapes"
fi

echo
echo "== contents"
for want in module.info config.info config lang/en openvpn-server-lib.pl \
            index.cgi install_check.pl download.cgi add.cgi revoke.cgi \
            server.cgi set_port.cgi apply_config.cgi settings.cgi \
            save_settings.cgi; do
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

# Webmin compares module versions numerically when deciding about updates,
# and reads depends as either a minimum Webmin version or a list of modules.
version=$(printf '%s\n' "$info" | sed -n 's/^version=//p')
case "$version" in
    ''|*[!0-9.]*) fail "version is numeric" "version=$version is not" ;;
    *) pass "version is numeric ($version)" ;;
esac

# Webmin compares versions numerically, so a third component would be read as
# nothing: perl evaluates 1.0.7 as 1, and every module shipped with 2.653 uses
# two parts. A three-part version here would break update detection silently.
parts=$(printf '%s' "$version" | awk -F. '{print NF}')
assert_eq "the version has two parts, as Webmin compares them" "2" "$parts"

if [ -n "${EXPECT_VERSION:-}" ]; then
    assert_eq "the package carries the version the build stamped" \
        "$EXPECT_VERSION" "$version"
fi

depends=$(printf '%s\n' "$info" | sed -n 's/^depends=//p')
case "$depends" in
    ''|*[!0-9.\ ]*) fail "depends is a Webmin version" "depends=$depends names something else" ;;
    *) pass "depends is a Webmin version ($depends)" ;;
esac
if [ -n "${WEBMIN_REF:-}" ]; then
    lowest=$(printf '%s\n%s\n' "$depends" "$WEBMIN_REF" | sort -V | head -1)
    assert_eq "the declared minimum is not above the tested Webmin" \
        "$depends" "$lowest"
fi

# perldepends is eval-ed by the installer, so anything named here must load
# on the target or the install fails with a message about CPAN.
perldeps=$(printf '%s\n' "$info" | sed -n 's/^perldepends=//p')
for mod in $perldeps; do
    if perl -e "use $mod; 1" >/dev/null 2>&1; then
        pass "perldepends $mod loads"
    else
        fail "perldepends $mod loads" "the installer would reject this"
    fi
done

echo
echo "== file modes inside the package"
# Webmin execs CGIs directly, so a non-executable one is a 500 error. This is
# not a style rule: all 2331 .cgi files shipped with Webmin 2.653 are 755,
# without exception. Library .pl files are do()-ed rather than executed and
# their mode varies even upstream (65 of 69 install_check.pl are 755, the
# rest 644), so requiring it of them would be inventing a rule Webmin does
# not have.
nonexec=$(tar -tvzf "$package" | awk '$NF ~ /\.cgi$/ && $1 !~ /^-..x/ { print $NF }')
if [ -z "$nonexec" ]; then
    pass "every .cgi is executable"
else
    fail "every .cgi is executable" "$nonexec"
fi

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

echo
echo "== the assets a release publishes are runnable"
# git modes across this tree are not uniform - vpn-server is recorded 644,
# vpn-client 755 - and nothing noticed because everything invokes them
# through bash and the package sets its own modes. Somebody downloading a
# tool from a release and running it directly would notice.
dist=$(dirname "$package")/dist
if [ -d "$dist" ]; then
    for t in vpn-client vpn-server install.sh; do
        if [ ! -e "$dist/$t" ]; then
            fail "$t is in the release" "missing from $dist"
        elif [ -x "$dist/$t" ]; then
            pass "$t is executable as published"
        else
            fail "$t is executable as published" "mode $(stat -c %a "$dist/$t")"
        fi
    done
else
    echo "[note] no dist directory yet; run make dist to check the assets"
fi

report
