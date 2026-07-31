# Security Policy

## Supported Versions

Only the latest release of Terminal receives security fixes. There is no
release host or in-app update feed configured yet, so builds are made from
source; see [CONTRIBUTING.md](CONTRIBUTING.md).

## Reporting a Vulnerability

Please use GitHub private vulnerability reporting:
https://github.com/tigercosmos/terminal/security/advisories/new

Please don't open a public issue for anything you believe is
exploitable before it has been fixed. Include reproduction steps and
the Terminal version (Terminal → About Terminal) you tested.

## Scope

Terminal embeds libghostty (vendored in `Vendor/libghostty-spm`) for
terminal emulation. In scope here: Terminal's configuration and host
integration of it — clipboard access, escape-sequence handling that
crosses a trust boundary, the update chain, what a repository's own Git
configuration can make the app execute, what a host reached over ssh can
make the app do with files on this machine, and anything that lets terminal
output reach data outside the session. Vulnerabilities in
upstream Ghostty itself should also be reported to the Ghostty
project: https://github.com/ghostty-org/ghostty/security.

When a terminal is inside an ssh session, the Files panel opens its own
connection to the same host to list directories and read files. A host you
connect to is therefore a source of untrusted input in the same way terminal
output is: what it answers with decides what the panel shows and where a
row's path points. It is under no obligation to run the command Terminal
sent it. Anything that lets such an answer reach the local file system, or
misrepresent what a row is, belongs in a report.
