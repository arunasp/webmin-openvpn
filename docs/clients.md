# Installing a client

A profile issued by this module is a single `.ovpn` file in the **unified
format**: the configuration plus the CA certificate, the client certificate,
the client private key and the `tls-crypt` key, all inline. Every current
OpenVPN client imports that one file unaided — nothing to unpack, no
certificates to place by hand, no paths to edit.

> The file contains the client's private key. Send it over something private.
> Not email, not a chat app. Once it is installed on the device, delete the
> copy you sent.

## Getting the file

In the module, **Servers → OpenVPN → Download** beside the client. The browser
saves it as `<name>.ovpn`.

From a shell on the server:

    vpn-client show laptop > laptop.ovpn

## Client support

| Platform | Client | Imports a unified `.ovpn` |
| --- | --- | --- |
| Windows 10/11 | OpenVPN GUI (community installer) | yes — Import file, Import from URL, or `--import` |
| Android | OpenVPN Connect, or OpenVPN for Android | yes |
| iOS / iPadOS | OpenVPN Connect | yes, and separate key files are not possible |
| macOS | Tunnelblick, or OpenVPN Connect | yes |
| Linux | `openvpn`, NetworkManager | yes |

Two constraints come from OpenVPN Connect's documentation and apply to
Android and iOS alike: a profile must be UTF-8 or ASCII, and must be under
256 KB. Profiles issued here are ASCII and a few kilobytes, and the test suite
asserts both, along with the absence of any directive naming a file the device
would not have.

## Windows

**OpenVPN GUI**, part of the official OpenVPN community installer:
<https://openvpn.net/community-downloads/>

Install it, then import the profile in any of these ways — each copies the
file into the GUI's configuration directory, after which the connection
appears in the system tray menu:

- right-click the tray icon → **Import** → **Import file…**, and select the
  `.ovpn`
- run `openvpn-gui.exe --import <path to .ovpn>`
- place the file in `%USERPROFILE%\OpenVPN\config\` yourself

The GUI needs no further configuration: the profile already names the server,
the port and the protocol. Note that its import copies exactly one file and
does not collect anything the configuration refers to by name, which is
another reason the unified format is the one to hand out.

## Android

**OpenVPN Connect**, published by OpenVPN Inc.:
<https://play.google.com/store/apps/details?id=net.openvpn.openvpn>

Alternatively **OpenVPN for Android** (ics-openvpn), open source:
<https://f-droid.org/packages/de.blinkt.openvpn/>

Transfer the `.ovpn` to the device and open it, or use **Import → File** inside
the app. With a unified profile that is the whole procedure. With an old-style
profile, every file it references must sit in the same directory on the device
— which is exactly the arrangement this module avoids.

## iOS and iPadOS

**OpenVPN Connect**: <https://apps.apple.com/app/openvpn-connect/id590379981>

Transfer the `.ovpn` to the device — AirDrop, Files, or a share sheet from
another app — and open it. iOS offers OpenVPN Connect as the handler, and the
profile imports with one tap.

On iOS the unified format is not merely convenient: iOS cannot import a
private key as a separate file, so a profile that references one cannot be
made to work without converting the certificate and key into a PKCS#12
bundle first.

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

The unified format removed the need. The certificates and the key are inside
the profile, and every client above imports a single file — none of them opens
an archive. Packaging one file into a zip would add a step for the user and
remove none.

## When a profile stops working

If the server's listening port or protocol changes, existing profiles name the
old one. Reissue them:

    vpn-client regen --all

`vpn-server set-port` does this automatically. A profile whose client has been
revoked cannot be repaired — issue a new client.
