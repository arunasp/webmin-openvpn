ifeq ($(wildcard /etc/cicd-common.mk),)
-include cicd-common.mk
else
include /etc/cicd-common.mk
endif

# Pipeline for the openvpn-server Webmin module and the shell tools it wraps.
# make perldeps once, then make all. Beyond that: make e2e when a change
# touches init, since that stage runs easy-rsa itself; make e2e-tunnel to
# connect a client through a server it built; make e2e-webmin to drive the
# module over HTTP in an installed Webmin. The last two need a container
# engine. make help lists everything.
#
# There is no deploy target. Installing to /usr/share/webmin on a server
# needs credentials no CI runner has, so it is driven from outside and
# recorded in DEPLOY.md rather than pretended at here.

MODULE   ?= openvpn-server

# VERSION holds major.minor. The third component is the build number, supplied
# by CI, so a release is major.minor.build and every build of the same source
# is distinguishable.
#
# module.info cannot carry that. Webmin compares module versions NUMERICALLY
# when deciding whether an update is newer, and Perl reads "1.0.7" as 1, which
# makes 1.0.7 < 1.0.10 false. All 114 modules shipped with Webmin 2.653 use two
# parts for exactly this reason. So the file gets major.build - two parts,
# numeric and monotonic - while the release and the artifact carry all three.
BASE_VERSION    = $(shell cat VERSION)
BUILD_NUMBER   ?= 0
RELEASE_VERSION = $(BASE_VERSION).$(BUILD_NUMBER)
MODULE_VERSION  = $(word 1,$(subst ., ,$(BASE_VERSION))).$(BUILD_NUMBER)
TOOLS     = $(wildcard tools/vpn-*)
SUITE     = $(wildcard tests/*.sh)
PERLSRC   = $(wildcard $(MODULE)/*.cgi) $(wildcard $(MODULE)/*.pl)
BUILD    ?= build
PACKAGE   = $(BUILD)/$(MODULE)-$(RELEASE_VERSION).wbm.gz

# CPAN dependencies live on the project tree, not in the container and not in
# the system perl: the worker is unprivileged and discarded after every call,
# so anything installed anywhere else is gone before the next stage runs.
PERL_LIB   = local/lib/perl5
PERLCRITIC = local/bin/perlcritic
CPANM      = .cpanm/cpanm
# tests/stubs supplies a compile-time WebminCore, without which no Webmin
# module can be checked anywhere but a host with Webmin installed.
PERL_ENV   = PERL5LIB=$(CURDIR)/$(PERL_LIB):$(CURDIR)/tests/stubs

# easy-rsa itself, from its own repository so the release tags are visible
# and e2e can run against more than one of them. Cached on the project tree
# like every other dependency here.
#
# A blob-filtered clone is 11 MB against 70 MB for a full one, and still
# carries every tag. Note the difference from a release tarball: in the git
# tree the version string is the unsubstituted placeholder ~VER~ and the
# script lives under easyrsa3/, because the tarball is a built artifact and
# this is the source.
# Webmin itself, pinned to the version the target host runs. The compile-time
# stub cannot tell a shipped ui_* function from a typo, so this is the only check
# that catches a call that does not exist in the release it will run on.
WEBMIN_REF    ?= 2.653
WEBMIN_REPO    = https://github.com/webmin/webmin.git
WEBMIN_CLONE   = .webmin/webmin
WEBMIN_REAL    = $(WEBMIN_CLONE)/ui-lib.pl

EASYRSA_REF   ?= v3.1.7
EASYRSA_REFS  ?= v3.1.7 v3.2.6
EASYRSA_REPO   = https://github.com/OpenVPN/easy-rsa.git
EASYRSA_CLONE  = .easyrsa/easy-rsa
EASYRSA_SRC   = $(EASYRSA_CLONE)/easyrsa3/easyrsa

.PHONY: perldeps easyrsa webmin apicheck lint scan style docs test build deb dist verify reproducible preflight smoke version e2e e2e-matrix e2e-tunnel e2e-webmin all clean distclean

version: ## Print the release version this build would produce
	@echo "release  $(RELEASE_VERSION)"
	@echo "module   $(MODULE_VERSION)   (module.info; two parts, numeric)"
	@echo "package  $(notdir $(PACKAGE))"

# Sentinel, kept out of .PHONY: a phony listing would reinstall 37
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
$(EASYRSA_SRC):
	@mkdir -p .easyrsa
	git clone -q --filter=blob:none $(EASYRSA_REPO) $(EASYRSA_CLONE)
	git -C $(EASYRSA_CLONE) -c advice.detachedHead=false checkout -q $(EASYRSA_REF)
	@test -x $@ || { echo "$@ missing after checkout"; exit 1; }

easyrsa: $(EASYRSA_SRC) ## Clone easy-rsa and check out EASYRSA_REF

$(WEBMIN_REAL):
	@mkdir -p .webmin
	git clone -q --filter=blob:none $(WEBMIN_REPO) $(WEBMIN_CLONE)
	git -C $(WEBMIN_CLONE) -c advice.detachedHead=false checkout -q $(WEBMIN_REF)
	@test -f $@ || { echo "$@ missing after checkout"; exit 1; }

webmin: $(WEBMIN_REAL) ## Clone Webmin and check out WEBMIN_REF

apicheck: $(WEBMIN_REAL) ## Check every Webmin function the module calls exists
	git -C $(WEBMIN_CLONE) -c advice.detachedHead=false checkout -q $(WEBMIN_REF)
	MODULE=$(MODULE) bash tests/webmin-api.sh $(WEBMIN_CLONE)

lint: scan style docs ## Leak scan, prose, docs, ShellCheck, and Perl checks
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

# Read-only checks against a live installation, to be run on the server after
# installing. Not part of any other target: it needs a working server, and
# there is not one here.
smoke: ## Check a live installation, read-only
	bash tests/smoke.sh

# Filler words that keep coming back. Checked rather than remembered,
# because remembering is what failed.
# Documentation goes stale without erroring. These are the facts in it that
# the tree can contradict: make targets, module settings, pinned versions,
# release examples, internal links.
docs: ## Check documented facts against the tree
	bash tests/docs.sh

style: ## Fail on filler words in tracked files
	bash tests/style.sh

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
	@test -n "$(BASE_VERSION)" || { echo "VERSION is empty"; exit 1; }
	@mkdir -p $(BUILD)
	@rm -rf $(BUILD)/stage
	@mkdir -p $(BUILD)/stage
	@cp -a $(MODULE) $(BUILD)/stage/$(MODULE)
	@sed -i 's/^version=.*/version=$(MODULE_VERSION)/' \
	  $(BUILD)/stage/$(MODULE)/module.info
	tar --exclude='*.bak-*' --exclude='.*' \
	  --sort=name --owner=0 --group=0 --numeric-owner \
	  --mtime=@$(SOURCE_DATE_EPOCH) \
	  --format=gnu -C $(BUILD)/stage -cf - $(MODULE) | gzip -n > $(PACKAGE)
	@rm -rf $(BUILD)/stage
	@cd $(BUILD) && sha256sum $(notdir $(PACKAGE)) > $(notdir $(PACKAGE)).sha256
	@ls -l $(PACKAGE)
	@cat $(PACKAGE).sha256

verify: build ## Check the package against what Webmin's installer requires
	MODULE=$(MODULE) WEBMIN_REF=$(WEBMIN_REF) \
	  EXPECT_VERSION=$(MODULE_VERSION) \
	  bash tests/verify-package.sh $(PACKAGE)
	@$(MAKE) --no-print-directory reproducible

# A distribution package for the two tools, so a server can install them the
# way it installs anything else - with dependencies the package manager
# enforces and a clean removal path.
#
# /usr/sbin rather than /usr/local/sbin: Debian policy reserves /usr/local for
# the administrator and a package must not write there. The module resolves
# either location, so the choice costs the operator nothing.
DEB_NAME    = openvpn-server-tools
DEB_FILE    = $(BUILD)/$(DEB_NAME)_$(RELEASE_VERSION)_all.deb

deb: ## Build a .deb of the two tools
	@command -v dpkg-deb >/dev/null 2>&1 || { \
	  echo "dpkg-deb is required to build a package"; exit 1; \
	}
	@rm -rf $(BUILD)/deb
	@mkdir -p $(BUILD)/deb/DEBIAN $(BUILD)/deb/usr/sbin
	@sed 's/@VERSION@/$(RELEASE_VERSION)/' packaging/deb/control.in \
	  > $(BUILD)/deb/DEBIAN/control
	@install -m 0755 tools/vpn-client tools/vpn-server $(BUILD)/deb/usr/sbin/
	@install -m 0755 tools/upnp-port-forward tools/vpn-extip $(BUILD)/deb/usr/sbin/
	dpkg-deb --root-owner-group --build $(BUILD)/deb $(DEB_FILE)
	@dpkg-deb -I $(DEB_FILE) | sed -n '2,7p'

# Everything a server installs, in one place with one checksum file. The
# module ships as a package; the two tools do not, and a server that takes
# them from anywhere else is running half a release. A target host has no
# git and no gh, so the assets have to be plain files behind plain URLs.
dist: build deb ## Assemble the release assets and their checksums
	@rm -rf $(BUILD)/dist
	@mkdir -p $(BUILD)/dist
	@cp $(PACKAGE) $(BUILD)/dist/
	@cp $(DEB_FILE) $(BUILD)/dist/
	@install -m 0755 tools/vpn-client tools/vpn-server \
	  tools/upnp-port-forward tools/vpn-extip $(BUILD)/dist/
	@install -m 0755 packaging/install.sh $(BUILD)/dist/
	@cd $(BUILD)/dist && sha256sum * > SHA256SUMS
	@ls -l $(BUILD)/dist
	@cat $(BUILD)/dist/SHA256SUMS

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

e2e: verify apicheck $(EASYRSA_SRC) ## Against easy-rsa and Webmin (needs network)
	git -C $(EASYRSA_CLONE) -c advice.detachedHead=false checkout -q $(EASYRSA_REF)
	bash tests/e2e-easyrsa.sh $(EASYRSA_SRC)

# EASYRSA_REFS leaves out easy-rsa 3.0.x: it prompts for a
# passphrase despite nopass, so it cannot be driven unattended at all. The
# tools fail fast against it rather than hanging, which is the most that can
# be done from this side.
e2e-matrix: verify $(EASYRSA_SRC) ## Run e2e against every ref in EASYRSA_REFS
	@for ref in $(EASYRSA_REFS); do \
	  echo "===== easy-rsa $$ref ====="; \
	  git -C $(EASYRSA_CLONE) -c advice.detachedHead=false checkout -q "$$ref" || exit 1; \
	  bash tests/e2e-easyrsa.sh $(EASYRSA_SRC) || exit 1; \
	done

# Installs the built package into an installed Webmin and drives the module over
# HTTP: the client list, the download page, the profile itself and the
# refusals. Nothing else can tell whether a page renders - the compile-time
# stub implements nothing - and the first hand run of this found
# JSON that broke the server panel whenever nobody was connected.
#
# It installs into the shared module directory and needs root, so it belongs
# in a container. The system configuration is left alone: /etc/webmin is
# copied and miniserv runs against the copy on a spare port.
e2e-webmin: ## Drive the module through Webmin, in a container
	@command -v docker >/dev/null 2>&1 || { \
	  echo "docker is required: this stage installs a module into the"; \
	  echo "shared Webmin directory and needs root."; \
	  exit 1; \
	}
	docker build -q -f tests/docker/Dockerfile.webmin -t openvpn-server-webmin .
	docker run --rm --ulimit nproc=8192:8192 openvpn-server-webmin

# The only stage that proves the software does what it is for: a server,
# a client, and a certificate that stops working when it is revoked.
# It needs a container, because a live tunnel wants a network namespace of its
# own and root to configure an interface - neither of which belongs to a test
# runner. Run it where a container engine exists.
# --ulimit nproc: RLIMIT_NPROC is enforced per real UID system-wide, not per
# container, and Docker daemon defaults can be as low as 128:256 - low enough
# that an ordinary desktop session already exceeds it. When it is exceeded,
# the next execve fails with EAGAIN for every binary, which reads as a broken
# image rather than a resource limit. This applies to root as much as to any
# other uid, so it is set regardless of who the container runs as.
#
# No --user here: neither container bind-mounts a host path, so
# nothing is written outside it to be left root-owned, and both need root -
# one for NET_ADMIN and a tun device, the other to install into Webmin.
e2e-tunnel: ## Build a server and connect a client through it, in a container
	@command -v docker >/dev/null 2>&1 || { \
	  echo "docker is required for this stage; the tunnel needs its own"; \
	  echo "network namespace and a tun device. Run it where docker exists."; \
	  exit 1; \
	}
	docker build -q -f tests/docker/Dockerfile -t openvpn-server-e2e .
	docker run --rm --network none \
	  --device /dev/net/tun --cap-add NET_ADMIN \
	  --ulimit nproc=8192:8192 \
	  openvpn-server-e2e

# e2e stays out of all: it downloads. Run it before trusting any
# change to init, because the mocked suite cannot see what easy-rsa itself does.
all: lint test verify ## Run every stage that needs no network

clean: ## Remove build artifacts
	rm -rf $(BUILD)

distclean: clean ## Also remove cached dependencies and their download caches
	rm -rf local .cpanm .perldeps .easyrsa .webmin
