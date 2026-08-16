ifeq ($(wildcard /etc/cicd-common.mk),)
-include cicd-common.mk
else
include /etc/cicd-common.mk
endif

# Pipeline for the openvpn-server Webmin module and the shell tools it wraps.
# make perldeps once, then make all. Run make e2e when a
# change touches init, because only that stage sees the real easy-rsa.
#
# deploy is deliberately absent. Installing to /usr/share/webmin on a server
# needs credentials no CI runner has, so it is driven from outside and
# recorded in DEPLOY.md rather than pretended at here.

MODULE   ?= openvpn-server
# Read from module.info rather than repeated here: Webmin already treats that
# file as the version of record, and a second copy is a second thing to
# forget. The artifact carries it so a downloaded file says what it is.
MODULE_VERSION = $(shell sed -n 's/^version=//p' $(MODULE)/module.info)
TOOLS     = $(wildcard tools/vpn-*)
SUITE     = $(wildcard tests/*.sh)
PERLSRC   = $(wildcard $(MODULE)/*.cgi) $(wildcard $(MODULE)/*.pl)
BUILD    ?= build
PACKAGE   = $(BUILD)/$(MODULE)-$(MODULE_VERSION).wbm.gz

# CPAN dependencies live on the project tree, not in the container and not in
# the system perl: the worker is unprivileged and discarded after every call,
# so anything installed anywhere else is gone before the next stage runs.
PERL_LIB   = local/lib/perl5
PERLCRITIC = local/bin/perlcritic
CPANM      = .cpanm/cpanm
# tests/stubs supplies a compile-time WebminCore, without which no Webmin
# module can be checked anywhere but a host with Webmin installed.
PERL_ENV   = PERL5LIB=$(CURDIR)/$(PERL_LIB):$(CURDIR)/tests/stubs

# The real easy-rsa, from its own repository so the release tags are visible
# and e2e can run against more than one of them. Cached on the project tree
# like every other dependency here.
#
# A blob-filtered clone is 11 MB against 70 MB for a full one, and still
# carries every tag. Note the difference from a release tarball: in the git
# tree the version string is the unsubstituted placeholder ~VER~ and the
# script lives under easyrsa3/, because the tarball is a built artifact and
# this is the source.
# Webmin itself, pinned to the version the target host runs. The compile-time
# stub cannot tell a real ui_* function from a typo, so this is the only check
# that catches a call that does not exist in the release it will run on.
WEBMIN_REF    ?= 2.653
WEBMIN_REPO    = https://github.com/webmin/webmin.git
WEBMIN_CLONE   = .webmin/webmin
WEBMIN_REAL    = $(WEBMIN_CLONE)/ui-lib.pl

EASYRSA_REF   ?= v3.1.7
EASYRSA_REFS  ?= v3.1.7 v3.2.6
EASYRSA_REPO   = https://github.com/OpenVPN/easy-rsa.git
EASYRSA_CLONE  = .easyrsa/easy-rsa
EASYRSA_REAL   = $(EASYRSA_CLONE)/easyrsa3/easyrsa

.PHONY: perldeps easyrsa webmin apicheck lint scan test build verify reproducible preflight e2e e2e-matrix e2e-tunnel all clean distclean

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

# The checked-out script is the target, so the clone happens once. Pinning is
# by tag rather than checksum: a tag names a release the upstream project
# published, and git verifies the objects it fetched.
$(EASYRSA_REAL):
	@mkdir -p .easyrsa
	git clone -q --filter=blob:none $(EASYRSA_REPO) $(EASYRSA_CLONE)
	git -C $(EASYRSA_CLONE) -c advice.detachedHead=false checkout -q $(EASYRSA_REF)
	@test -x $@ || { echo "$@ missing after checkout"; exit 1; }

easyrsa: $(EASYRSA_REAL) ## Clone easy-rsa and check out EASYRSA_REF

$(WEBMIN_REAL):
	@mkdir -p .webmin
	git clone -q --filter=blob:none $(WEBMIN_REPO) $(WEBMIN_CLONE)
	git -C $(WEBMIN_CLONE) -c advice.detachedHead=false checkout -q $(WEBMIN_REF)
	@test -f $@ || { echo "$@ missing after checkout"; exit 1; }

webmin: $(WEBMIN_REAL) ## Clone Webmin and check out WEBMIN_REF

apicheck: $(WEBMIN_REAL) ## Check every Webmin function the module calls exists
	git -C $(WEBMIN_CLONE) -c advice.detachedHead=false checkout -q $(WEBMIN_REF)
	MODULE=$(MODULE) bash tests/webmin-api.sh $(WEBMIN_CLONE)

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

# Run this before pushing anywhere public. scan covers the working tree; a
# push publishes every commit, and history is where both previous leaks were.
preflight: ## Check the working tree AND every unpushed commit
	bash tests/preflight.sh

test: ## Run the tools against a fixture site with systemctl and id mocked
	bash tests/run.sh

# Reproducible by construction: sorted entries, no owner names, and every
# mtime pinned to the last commit. Two builds of the same tree then produce
# byte-identical packages, which is what makes a checksum worth publishing -
# and what lets verify prove the artifact matches the source it claims.
SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct 2>/dev/null || echo 0)

build: ## Package the module as a reproducible Webmin .wbm.gz
	@test -d $(MODULE) || { echo "$(MODULE)/ does not exist"; exit 1; }
	@test -n "$(MODULE_VERSION)" || { echo "no version= in $(MODULE)/module.info"; exit 1; }
	@mkdir -p $(BUILD)
	tar --exclude='*.bak-*' --exclude='.*' \
	  --sort=name --owner=0 --group=0 --numeric-owner \
	  --mtime=@$(SOURCE_DATE_EPOCH) \
	  --format=gnu -cf - $(MODULE) | gzip -n > $(PACKAGE)
	@cd $(BUILD) && sha256sum $(notdir $(PACKAGE)) > $(notdir $(PACKAGE)).sha256
	@ls -l $(PACKAGE)
	@cat $(PACKAGE).sha256

verify: build ## Check the package against what Webmin's installer requires
	MODULE=$(MODULE) WEBMIN_REF=$(WEBMIN_REF) \
	  bash tests/verify-package.sh $(PACKAGE)
	@$(MAKE) --no-print-directory reproducible

# A checksum nobody can reproduce is a number, not a guarantee.
reproducible: ## Rebuild and confirm the package is byte-identical
	@cp $(PACKAGE) $(BUILD)/.first.wbm.gz
	@$(MAKE) --no-print-directory build >/dev/null
	@if cmp -s $(BUILD)/.first.wbm.gz $(PACKAGE); then \
	  echo "[PASS] the package rebuilds byte-identically"; \
	else \
	  echo "[FAIL] the package is not reproducible"; exit 1; \
	fi
	@rm -f $(BUILD)/.first.wbm.gz

e2e: verify apicheck $(EASYRSA_REAL) ## Real easy-rsa and real Webmin (needs network)
	git -C $(EASYRSA_CLONE) -c advice.detachedHead=false checkout -q $(EASYRSA_REF)
	bash tests/e2e-real.sh $(EASYRSA_REAL)

# easy-rsa 3.0.x is deliberately absent from EASYRSA_REFS: it prompts for a
# passphrase despite nopass, so it cannot be driven unattended at all. The
# tools fail fast against it rather than hanging, which is the most that can
# be done from this side.
e2e-matrix: verify $(EASYRSA_REAL) ## Run e2e against every ref in EASYRSA_REFS
	@for ref in $(EASYRSA_REFS); do \
	  echo "===== easy-rsa $$ref ====="; \
	  git -C $(EASYRSA_CLONE) -c advice.detachedHead=false checkout -q "$$ref" || exit 1; \
	  bash tests/e2e-real.sh $(EASYRSA_REAL) || exit 1; \
	done

# The only stage that proves the software does what it is for: a real server,
# a real client, and a certificate that stops working when it is revoked.
# It needs a container, because a live tunnel wants a network namespace of its
# own and root to configure an interface - neither of which belongs to a test
# runner. Run it where a container engine exists.
e2e-tunnel: ## Build a server and connect a client through it, in a container
	@command -v docker >/dev/null 2>&1 || { \
	  echo "docker is required for this stage; the tunnel needs its own"; \
	  echo "network namespace and a tun device. Run it where docker exists."; \
	  exit 1; \
	}
	docker build -q -f tests/docker/Dockerfile -t openvpn-server-e2e .
	docker run --rm --network none \
	  --device /dev/net/tun --cap-add NET_ADMIN \
	  openvpn-server-e2e

# e2e is deliberately not in all: it downloads. Run it before trusting any
# change to init, because the mocked suite cannot see what the real tool does.
all: lint test verify ## Run every stage that needs no network

clean: ## Remove build artifacts
	rm -rf $(BUILD)

distclean: clean ## Also remove cached dependencies and their download caches
	rm -rf local .cpanm .perldeps .easyrsa .webmin
