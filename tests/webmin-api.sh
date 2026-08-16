#!/bin/bash
# Assert that every Webmin function this module calls exists in the Webmin
# version it will actually run on.
#
# The compile-time stub in tests/stubs makes `use WebminCore` compile
# anywhere, implementing nothing - so perl -cw and perlcritic
# cannot tell a shipped ui_* function from a typo. Neither can they tell a
# function that was removed between Webmin releases. This closes that gap
# against a checkout of Webmin itself.
#
# What it proves: the name exists as a sub in that release.
# What it does NOT prove: that we pass the right arguments, or that the page
# renders. Only a browser answers that, which is why DEPLOY.md still asks for
# one. Argument contracts were read by hand against 2.653:
#
#   ui_print_header($text, @args)
#   ui_table_start($heading, $tabletags, $cols, $tds, $rightheading)
#   ui_table_row($label, $value)
#   ui_columns_table($heads, $width, $data, $types, $nosort, $title, $empty)
#   ui_alert_box($msg, $type)          type: success | info | warn | danger
#   ui_form_start($script, $method)
#   ui_form_end($buttons, $width)      buttons: [ [ name, label, ... ], ... ]
#   ui_textbox($name, $value, $size, $dis, $max, $tags, $cls)
#
# Takes the path to a Webmin checkout as its first argument.
set -uo pipefail

webmin=${1:?usage: webmin-api.sh <path-to-webmin-checkout>}
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
module=${MODULE:-openvpn-server}
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

if [ ! -f "$webmin/ui-lib.pl" ]; then
    fail "webmin checkout is usable" "$webmin/ui-lib.pl not found"
    report
    exit 1
fi

# The in-tree version file lags the tag: at tag 2.653 it still reads 2.652,
# because Webmin bumps it when the package is built. The ref is the honest
# identifier. Verified empirically - ui-lib.pl and web-lib-funcs.pl at tag
# 2.653 are byte-identical to the files installed by the webmin 2.653 package.
version=$(git -C "$webmin" describe --tags --exact-match 2>/dev/null)
[ -n "$version" ] || version=$(git -C "$webmin" rev-parse --short HEAD 2>/dev/null)
[ -n "$version" ] || version=$(sed -n '1p' "$webmin/version" 2>/dev/null)
echo "== module $module against Webmin ${version:-unknown} ($webmin)"

# Functions the module calls, minus the ones it defines itself: those are
# ours to keep working and are covered by the rest of the suite.
# Mixed case matters: ReadParse, PrintHeader and friends are Webmin's, and a
# lowercase-only pattern silently checked none of them.
called=$(grep -rhoE '&[A-Za-z_][A-Za-z0-9_]*\(' "$repo/$module" | tr -d '&(' | sort -u)
ours=$(grep -rhoE '^sub [A-Za-z_][A-Za-z0-9_]*' "$repo/$module" | sed 's/^sub //' | sort -u)
external=$(comm -23 <(printf '%s\n' "$called") <(printf '%s\n' "$ours"))

if [ -z "$external" ]; then
    fail "the module calls Webmin at all" "no external functions found - is the grep still right?"
    report
    exit 1
fi

for fn in $external; do
    if grep -rqE "^sub $fn\$" --include='*.pl' "$webmin" 2>/dev/null; then
        pass "$fn is defined in Webmin ${version:-?}"
    else
        fail "$fn is defined in Webmin ${version:-?}" "no 'sub $fn' anywhere in the checkout"
    fi
done

echo
echo "== module.info fields Webmin actually reads"
# Webmin parses module.info as name=value; these are the ones that decide
# whether the module appears and where.
for field in name desc category version; do
    assert_file_contains "module.info declares $field" \
        "$repo/$module/module.info" "^$field="
done

# install_check.pl is called by Webmin to decide whether to show the module.
if [ -f "$repo/$module/install_check.pl" ]; then
    assert_file_contains "install_check.pl defines is_installed" \
        "$repo/$module/install_check.pl" "^sub is_installed"
fi

report
