package WebminCore;

# Compile-time stand-in for Webmin's own WebminCore, which exists only on a
# host with Webmin installed. `use WebminCore` runs at compile time, so
# without this no Webmin module can be syntax-checked or policy-checked
# anywhere else - which would mean the only place to find a typo is a browser
# on a production server.
#
# THIS IS NOT USED AT RUNTIME and deliberately implements nothing. Webmin
# exports its ui_* helpers into the caller; module code calls them in the
# &name(...) form, which compiles without a declaration and resolves for real
# when Webmin loads the module. So an empty import is enough to compile
# against, and cannot drift from the real API by pretending to be it.
#
# What this does NOT prove: that any ui_* call is correct, that its arguments
# are right, or that the page renders. Only Webmin itself answers that, in a
# browser. See DEPLOY.md.

use strict;
use warnings;

sub import { return; }

1;
