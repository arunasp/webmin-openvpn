# Installing a client

A profile issued by this module is a single `.ovpn` file containing the
configuration, the CA certificate, the client certificate, the client private
key and the `tls-crypt` key. Every current OpenVPN client imports that one file
unaided — there is nothing to unpack, no certificates to place by hand and no
paths to edit.

> The file contains the client's private key. Send it over something private.
> Not email, not a chat app. Once it is installed on the device, delete the
> copy you sent.

## Getting the file

In the module, **Servers → OpenVPN → Download** beside the client. The browser
saves it as `<name>.ovpn`.

From a shell on the server:

    vpn-client show laptop > laptop.ovpn

## Windows

**OpenVPN GUI**, part of the official OpenVPN community installer:
<https://openvpn.net/community-downloads/>

Install it, then import the profile in any of these ways — all three copy the
file into the GUI's configuration directory, after which the connection
appears in the system tray menu:

- right-click the tray icon → **Import** → **Import file…**, and select the
  `.ovpn`
- run `openvpn-gui.exe --import <path to .ovpn>`
- place the file in `%USERPROFILE%\OpenVPN\config\` yourself

The GUI needs no further configuration: the profile already names the server,
the port and the protocol.

## Android

**OpenVPN Connect**, published by OpenVPN Inc.:
<https://play.google.com/store/apps/details?id=net.openvpn.openvpn>

Alternatively **OpenVPN for Android** (ics-openvpn), open source:
<https://f-droid.org/packages/de.blinkt.openvpn/>

Transfer the `.ovpn` to the device and open it, or use **Import → File** inside
the app. Either client reads the inline certificates directly.

## iOS and iPadOS

**OpenVPN Connect**: <https://apps.apple.com/app/openvpn-connect/id590379981>

Transfer the `.ovpn` to the device — AirDrop, Files, or a share sheet from
another app — and open it. iOS offers OpenVPN Connect as the handler, and the
profile imports with one tap.

## macOS

**Tunnelblick**: <https://tunnelblick.net/> — double-click the `.ovpn`.

**OpenVPN Connect**: <https://openvpn.net/client/> also runs on macOS.

## Linux

    openvpn --config laptop.ovpn

Or with NetworkManager:

    nmcli connection import type openvpn file laptop.ovpn

## Why there is no bundle to download

The module in this repository's `openvpn/` directory offered a zip containing
`ca.crt`, `client.crt`, `client.key`, `ta.key`, the configuration and a pair of
Windows batch scripts. That was necessary because its configuration referenced
those files by name, so a client needed all of them in one directory.

An inline profile does not: the certificates and keys are inside the file. None
of the clients above can import a zip, so packaging one file into an archive
would add a step for the user and remove one for nobody.

## When a profile stops working

If the server's listening port or protocol changes, existing profiles name the
old one. Reissue them:

    vpn-client regen --all

`vpn-server set-port` does this automatically. A profile whose client has been
revoked cannot be repaired — issue a new client.
