ifeq ($(wildcard /etc/cicd-common.mk),)
-include cicd-common.mk
else
include /etc/cicd-common.mk
endif

# Pipeline for the openvpn-server Webmin module and the shell tools it wraps.
# Run through cicd_runner: make perldeps once, then make all.
#
# deploy is deliberately absent. Installing to /usr/share/webmin on the
# bastion needs ssh credentials no worker has, so it is driven from outside
# and recorded in DEPLOY.md rather than pretended at here.

MODULE   ?= openvpn-server
TOOLS     = $(wildcard tools/vpn-*)
SUITE     = $(wildcard tests/*.sh)
PERLSRC   = $(wildcard $(MODULE)/*.cgi) $(wildcard $(MODULE)/*.pl)
BUILD    ?= build

# CPAN dependencies live on the project tree, not in the container and not in
# the system perl: the worker is unprivileged and discarded after every call,
# so anything installed anywhere else is gone before the next stage runs.
PERL_LIB   = local/lib/perl5
PERLCRITIC = local/bin/perlcritic
CPANM      = .cpanm/cpanm
# tests/stubs supplies a compile-time WebminCore, without which no Webmin
# module can be checked anywhere but a host with Webmin installed.
PERL_ENV   = PERL5LIB=$(CURDIR)/$(PERL_LIB):$(CURDIR)/tests/stubs

.PHONY: perldeps lint scan test build verify e2e all clean distclean

# Sentinel, deliberately NOT in .PHONY: a phony listing would reinstall 37
# distributions on every invocation.
.perldeps: cpanfile
	@mkdir -p .cpanm
	@test -f $(CPANM) || curl -sSL -o $(CPANM) https://cpanmin.us
	@chmod +x $(CPANM)
	PERL_CPANM_HOME=$(CURDIR)/.cpanm perl $(CPANM) --quiet --notest \
	  --local-lib-contained local --installdeps .
	@touch .perldeps

perldeps: .perldeps ## Install CPAN dependencies into ./local

lint: scan ## Leak scan, ShellCheck, and Perl compile and policy checks
	@test -n "$(TOOLS)" || { echo "no tools found to check"; exit 1; }
	shellcheck --shell=bash $(TOOLS) $(SUITE)
	@for f in $(PERLSRC); do echo "perl -cw $$f"; $(PERL_ENV) perl -cw "$$f" || exit 1; done
	@if [ -z "$(strip $(PERLSRC))" ]; then \
	  echo "no perl sources yet - compile and policy checks had nothing to do"; \
	elif [ -x $(PERLCRITIC) ]; then \
	  $(PERL_ENV) $(PERLCRITIC) $(PERLSRC); \
	else \
	  echo "perlcritic absent - run 'make perldeps'; compile check only this run"; \
	fi

scan: ## Fail if site identity or key material reached the tree
	python3 tests/scan.py

test: ## Run the tools against a fixture site with systemctl and id mocked
	bash tests/run.sh

build: ## Package the module as a Webmin .wbm.gz
	@test -d $(MODULE) || { echo "$(MODULE)/ does not exist"; exit 1; }
	@mkdir -p $(BUILD)
	tar --exclude='*.bak-*' --exclude='.*' \
	  -czf $(BUILD)/$(MODULE).wbm.gz $(MODULE)
	@ls -l $(BUILD)/$(MODULE).wbm.gz

verify: build ## Check the package a browser would receive
	MODULE=$(MODULE) bash tests/verify-package.sh $(BUILD)/$(MODULE).wbm.gz

e2e: verify ## Alias for verify; the real end-to-end path is a browser

all: lint test verify ## Run every stage that currently has inputs

clean: ## Remove build artifacts
	rm -rf $(BUILD)

distclean: clean ## Also remove the cached CPAN install and its download cache
	rm -rf local .cpanm .perldeps
