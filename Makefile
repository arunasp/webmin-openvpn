ifeq ($(wildcard /etc/cicd-common.mk),)
-include cicd-common.mk
else
include /etc/cicd-common.mk
endif

# Pipeline for the openvpn-server Webmin module and the shell tools it wraps.
# Run through cicd_runner: make perldeps once, then make all. make e2e when a
# change touches init, because only that stage sees the real easy-rsa.
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

# The real easy-rsa, pinned and checksummed, cached on the project tree like
# every other dependency here. e2e needs the genuine tool: the suite's fake
# cannot prove that easy-rsa honours what init asks it for, and that is
# exactly where a defect hid once already.
EASYRSA_VERSION ?= 3.1.7
EASYRSA_SHA256  ?= aaa48fadcbb77511b9c378554ef3eae09f8c7bc149d6f56ba209f1c9bab98c6e
EASYRSA_URL      = https://github.com/OpenVPN/easy-rsa/releases/download/v$(EASYRSA_VERSION)/EasyRSA-$(EASYRSA_VERSION).tgz
EASYRSA_HOME     = .easyrsa/EasyRSA-$(EASYRSA_VERSION)
EASYRSA_REAL     = $(EASYRSA_HOME)/easyrsa

.PHONY: perldeps easyrsa lint scan test build verify e2e all clean distclean

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

# The extracted binary is the target, so this runs once and not again. The
# checksum is not decoration: an unverified download is an unpinned
# dependency wearing a version number.
$(EASYRSA_REAL):
	@mkdir -p .easyrsa
	curl -sSL -o .easyrsa/easyrsa.tgz $(EASYRSA_URL)
	echo "$(EASYRSA_SHA256)  .easyrsa/easyrsa.tgz" | sha256sum -c -
	tar -xzf .easyrsa/easyrsa.tgz -C .easyrsa
	@test -x $@ || { echo "$@ missing after extraction"; exit 1; }

easyrsa: $(EASYRSA_REAL) ## Fetch the pinned easy-rsa release into .easyrsa

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

e2e: verify $(EASYRSA_REAL) ## Also run init against the real easy-rsa (needs network)
	bash tests/e2e-real.sh $(EASYRSA_REAL)

# e2e is deliberately not in all: it downloads. Run it before trusting any
# change to init, because the mocked suite cannot see what the real tool does.
all: lint test verify ## Run every stage that needs no network

clean: ## Remove build artifacts
	rm -rf $(BUILD)

distclean: clean ## Also remove cached dependencies and their download caches
	rm -rf local .cpanm .perldeps .easyrsa
