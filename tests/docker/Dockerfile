# Image for the tunnel test: an OpenVPN server, a client, and a
# certificate authority, in a network namespace of their own.
#
# NOT based on openvpn/openvpn-as. That image is OpenVPN Access Server, a
# separate commercial product with its own configuration database, its own
# web administration interface and its own management tool. It does not use
# easy-rsa, /etc/openvpn/server/server.conf or openvpn-server@ units, so it
# shares nothing with what these tools manage; testing against it would
# exercise a different product.
#
# Ubuntu 24.04 instead, because the distribution packages are what a target
# host runs.

FROM ubuntu:24.04

# openvpn provides the daemon and the key generator; easy-rsa the CA. iproute2
# is not required by the test but makes the container debuggable by hand.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openvpn \
      easy-rsa \
      openssl \
      iproute2 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
# The repository, not a list of paths: an enumerated COPY restates the tree
# and drifts from it. .dockerignore names the exclusions.
COPY . /src

# Presence, not the executable bit: the entrypoint runs these through bash,
# and the git modes are not uniform across the tree.
RUN test -f /src/tools/vpn-client \
 && test -f /src/tools/vpn-server \
 && test -f /src/tests/e2e-tunnel.sh

# The daemon writes where the generated config tells it to, and that path has
# to exist before the server starts.
RUN mkdir -p /var/log/openvpn

# Both server and client run inside this container and talk over the loopback
# interface, so the container needs no network of its own - run it with
# --network none. It does need a tun device and the capability to configure
# interfaces: --device /dev/net/tun --cap-add NET_ADMIN.
ENTRYPOINT ["bash", "/src/tests/e2e-tunnel.sh"]
