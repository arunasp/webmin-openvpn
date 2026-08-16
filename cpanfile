# Static analysis for the Webmin module's Perl. perl -c only answers whether a
# file compiles; this is the nearest thing Perl has to ShellCheck.
#
# Installed into ./local by `make perldeps`, never system-wide: the CI worker
# is unprivileged and ephemeral, so the install has to land on the project
# tree to survive at all.
#
# Pinned, because an unpinned analyser changes its findings under you and a
# pipeline that fails intermittently teaches people to re-run until green.
# Transitive dependencies are NOT pinned - that needs a cpanfile.snapshot and
# Carton, which is not worth carrying until this list grows.
requires 'Perl::Critic', '== 1.156';
