<!-- SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors -->
<!-- SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later -->

# Security

## Release signing keys

Every DS release is signed. The public halves of the signing keys are in
[`KEYS`](KEYS) at the root of this repository: armoured OpenPGP public keys,
one after another, each under a `# <fingerprint>` line. The private halves
were generated on a smartcard and have never left it; they cannot be exported
from it.

A key lives 13 months. A new one is made about a month before the current one
expires, and the outgoing key certifies it, so a key you already trust vouches
for the next. A rotation adds a key to `KEYS` and never replaces one, because
every release signed under an earlier key has to keep verifying.

`KEYS` was cleared at the 0.20.0 cut, so it starts with the v1 key. 0.17.0 to
0.19.0 were signed by an earlier key whose public half is in each release's
notes; earlier releases by the daily keys in [`keys/`](keys).

The v1 key, which signs 0.20.0 and every later release until it rotates:

```
A1FF 7995 2433 37AE 056D  3FCD 2F31 8A97 E9CA E307
DS Release Signing <releases@ds-lang.org>, expires 2027-11-26
```

## Verifying a release

The fingerprint that signed a release is recorded in that release's own
`manifest.json`, as the `fingerprint` field, and in the release notes. That is
the authority — **not** membership of `KEYS`. A key being in `KEYS` means DS
held it, not that it signed the release in front of you. Compare the
fingerprint against more than one source before you trust it.

```sh
gpg --import KEYS
gpg --status-fd 1 --verify SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS
```

Require a positive `VALIDSIG` naming the fingerprint from that release's
`manifest.json`. **Do not read the exit code**: `gpg` exits 0 for a signature
made by a key that has since expired.

## Expiry is expected, and is not a failure

A release older than its signing key's 13 months is signed by a key that has
since expired. `gpg` reports this as `EXPKEYSIG`, which means *the signature is
good and the key has since expired* — not that the signature is bad. A
signature made while the key was valid stays valid.

`EXPKEYSIG` is a refusal when you are checking a release about to be
published, and the normal case when you are checking one from the archive.
The signature cannot tell the two apart, so you must know which you are doing.
