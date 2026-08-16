#!/usr/bin/env python3
"""Refuse to let site identity or key material into a public repository.

This scans for *classes* of leak rather than a list of the specific values
being kept out: a denylist of real hostnames would have to contain those
hostnames, which is the thing it is supposed to prevent. So the rules are
structural - a fully qualified domain name that is not a documentation
domain, an IPv4 address outside the declared set, a Windows drive path, a
private key header.

Run as part of the pipeline. It is not a substitute for the platform's own
push protection: this runs when someone invokes it, and any check the
committer can skip is advisory. It catches the accident, not the intent.
"""

import ipaddress
import re
import sys
from pathlib import Path

# Only our own work. The vendored upstream module is already public and is
# not ours to police.
INCLUDE_DIRS = ("tools", "tests", "openvpn-server", ".github", "docs")
INCLUDE_FILES = ("Makefile", "cicd-common.mk", "README.md", "DEPLOY.md",
                 "CONTRIBUTING.md", ".gitignore")
SKIP_NAMES = {"scan.py"}

# RFC 2606 reserves these for documentation, so any name under them is safe
# to write down.
DOC_SUFFIXES = (".example.com", ".example.org", ".example.net")
ALLOWED_HOSTS = {
    "example.com", "example.org", "example.net",
    "github.com", "www.github.com",
    "raw.githubusercontent.com", "shellcheck.net", "www.shellcheck.net",
    "openvpn.net", "community.openvpn.net", "webmin.com", "www.webmin.com",
    "users.noreply.github.com", "noreply.anthropic.com",
    # Where the pipeline fetches its own tooling from.
    "cpanmin.us", "metacpan.org", "cpan.metacpan.org", "cpan.org",
}

# Addresses this repository is allowed to write down. Everything else is a
# finding, including private addresses: "it is only an internal address" is
# precisely how a real internal address ends up published, and RFC 1918 space
# describes the topology of a specific site just as surely as a public one.
#
# The two private entries are the fixture's own LAN and the tunnel subnet in
# its server.conf. Adding a third means editing this list, which is the point
# - the friction is what makes someone notice they are writing a real address.
ALLOWED_NETWORKS = [
    ipaddress.ip_network("127.0.0.0/8"),        # loopback
    ipaddress.ip_network("169.254.0.0/16"),     # link-local
    ipaddress.ip_network("192.0.2.0/24"),       # RFC 5737 documentation
    ipaddress.ip_network("198.51.100.0/24"),    # RFC 5737 documentation
    ipaddress.ip_network("203.0.113.0/24"),     # RFC 5737 documentation
    ipaddress.ip_network("192.168.50.0/24"),    # the fixture's LAN
    ipaddress.ip_network("10.8.0.0/24"),        # the fixture's tunnel subnet
]

# Netmasks are not addresses. Prefixes shorter than /8 are deliberately
# excluded: 128.0.0.0 is far more likely to be an address than a mask.
NETMASKS = {ipaddress.ip_address("0.0.0.0")}
NETMASKS |= {
    ipaddress.ip_network(f"0.0.0.0/{bits}").netmask for bits in range(8, 33)
}

# A dotted name only counts as a hostname when its last label is a real
# public suffix. .sh, .pl and .info are deliberately absent: they are real
# TLDs but they collide with filenames this project cannot rename - run.sh,
# a Perl library, and Webmin's own module.info and config.info. A rule that
# fires on those is a rule that gets skipped. The cost is real and worth
# naming: a leaked host under .info or .sh would pass this check.
PUBLIC_TLDS = {
    "com", "net", "org", "io", "dev", "app", "co", "uk", "eu", "lt", "lv",
    "ee", "de", "fr", "nl", "ru", "biz", "xyz", "online",
    "site", "tv", "me", "cc", "us", "ch", "it", "es", "se", "no", "fi",
    "cloud", "host", "link", "live", "pro", "gg", "ai",
}
FQDN = re.compile(r"\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+([a-z]{2,})\b",
                  re.IGNORECASE)
IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
WINPATH = re.compile(r"\b[A-Za-z]:\\\\?[A-Za-z0-9_.\\\\ -]+")
SECRET = re.compile(
    r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"
    r"|-----BEGIN CERTIFICATE-----"
    r"|-----BEGIN OpenVPN Static key",
)
SECRET_SUFFIXES = (".key", ".crt", ".pem", ".ovpn", ".p12", ".pfx")


def address_finding(text):
    """Return a description of why this address may not appear, or None."""
    try:
        addr = ipaddress.ip_address(text)
    except ValueError:
        return None
    if addr in NETMASKS:
        return None
    for network in ALLOWED_NETWORKS:
        if addr in network:
            return None
    if addr.is_private:
        return "private address (real topology?)"
    return "routable IP"


def files_to_scan(root):
    for name in INCLUDE_FILES:
        path = root / name
        if path.is_file():
            yield path
    for directory in INCLUDE_DIRS:
        base = root / directory
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if path.is_file() and path.name not in SKIP_NAMES:
                yield path


def check_line(path, number, line, findings):
    for match in SECRET.finditer(line):
        findings.append((path, number, "key material", match.group(0)))
    for match in IPV4.finditer(line):
        reason = address_finding(match.group(0))
        if reason:
            findings.append((path, number, reason, match.group(0)))
    for match in FQDN.finditer(line):
        host = match.group(0).lower()
        if match.group(1).lower() not in PUBLIC_TLDS:
            continue
        if host in ALLOWED_HOSTS or host.endswith(DOC_SUFFIXES):
            continue
        findings.append((path, number, "hostname", host))
    for match in WINPATH.finditer(line):
        findings.append((path, number, "local path", match.group(0).strip()))


def main():
    # A root can be passed in so the same rules can be applied to an extracted
    # commit tree, not just the working copy. A push publishes every commit,
    # so checking only what is checked out proves very little.
    if len(sys.argv) > 1:
        root = Path(sys.argv[1]).resolve()
    else:
        root = Path(__file__).resolve().parent.parent
    findings = []

    for path in files_to_scan(root):
        rel = path.relative_to(root)
        if path.suffix in SECRET_SUFFIXES:
            findings.append((rel, 0, "key material file", path.name))
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            check_line(rel, number, line, findings)

    if findings:
        print("=== LEAK SCAN: FAILED ===")
        for path, number, kind, value in findings:
            where = f"{path}:{number}" if number else str(path)
            print(f"  {where}: {kind}: {value}")
        print()
        print("Site identity belongs in /etc/default/vpn-tools on the host,")
        print("not in the repository. See DEPLOY.md.")
        return 1

    print("=== LEAK SCAN: clean ===")
    print("no undeclared addresses, real hostnames, local paths"
          " or key material")
    return 0


if __name__ == "__main__":
    sys.exit(main())
