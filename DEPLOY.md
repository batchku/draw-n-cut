# Headless TestFlight deploys

Build, sign and upload from a chat session with nothing to click: no Xcode
Organizer, no signed-in Xcode account, no Apple ID prompt.

```sh
scripts/bootstrap_signing.sh      # once, ever (already done)
scripts/deploy-testflight.sh      # every release
```

---

## What changed, and why

The previous script archived with the API key but had to run the *export and
upload* step through the Mac's signed-in Xcode account. That is Apple's cloud
signing: Apple holds the distribution private key and signs server-side, and
cloud-managed assets are invisible to an API key. It works, but it needs a
logged-in Xcode on the machine, so it could not be driven remotely.

The fix is to stop depending on cloud signing. A distribution certificate
whose private key lives on this machine signs locally, and the whole path —
archive, sign, export, upload, wait — runs off the App Store Connect API key.

### The certificate is shared with Scoranger, on purpose

Apple caps distribution certificates per team at a small number, and revoking
one invalidates every build ever signed with it. Certificates are per *team*;
only the provisioning profile is per *app*. Both apps are team `V9DBGV72NL`
(IRL Labs LLC), so `bootstrap_signing.sh` **adopted** the certificate
Scoranger's bootstrap created rather than minting a second one:

| | |
|---|---|
| Certificate | `iPhone Distribution: IRL Labs LLC`, id `V9UVD49C95`, expires 2027-08-21 |
| Adopted from | `~/.scoranger-signing/` → copied to `~/.drawncut-signing/` |
| Profile created | `DrawNCut App Store (headless)`, id `5394QXRY46` — the only new Apple resource |
| Keychain | `~/Library/Keychains/drawncut-signing.keychain-db` |
| API key | `MJ85RP93GW` (Admin), shared with Scoranger |

Adoption is verified, not assumed: the certificate must be unexpired, issued
to this team, and matched by the private key beside it. A mismatched pair
would otherwise fail much later inside `codesign`, with a far less obvious
message.

**Consequence worth knowing:** revoking that certificate breaks TestFlight
uploads for *both* apps. It is one identity now.

### No Python environment

`scripts/lib/asc.py` signs its ES256 JWT by shelling out to `openssl` and
speaks HTTP with the standard library. Scoranger's copy imports the
`cryptography` package from its engine venv; this repo is Swift-only, and
adding a virtualenv as a build input for four API calls was not worth it. Any
`python3` works.

## Version and build numbers

Two numbers, two jobs, both in `project.yml`:

- **`MARKETING_VERSION`** (what the user sees: `0.2.0`) names the **feature
  set**. Edited by hand when a feature starts. Several builds share a version
  while its bugs are fixed.
- **`CURRENT_PROJECT_VERSION`** (the build number) counts **uploads**. Every
  ship takes the next one, bug fixes included. `scripts/bump_build.sh` owns
  it; nothing else may touch it, and Xcode must never manage it at upload time
  (`ExportOptions.plist` sets `manageAppVersionAndBuildNumber=false`).

Builds 1–45 numbered themselves from the git commit count. That coupled
shipping to committing — with the count sitting at exactly the last uploaded
build, a deploy without a new commit was rejected as a duplicate.
`CURRENT_PROJECT_VERSION` is now seeded at 45 and bumps explicitly, so the two
are independent.

Report both when you ship: the version says what it is, the build says which
upload.

## What is in the repo

| File | Role |
|---|---|
| `scripts/bootstrap_signing.sh` | One-time: adopt or create a certificate, keychain, profile |
| `scripts/deploy-testflight.sh` | Every release: bump, archive, sign, upload, wait |
| `scripts/lib/asc.py` | App Store Connect API client (openssl JWT, certs, profiles, build status) |
| `scripts/lib/deploy_common.sh` | Shared config, keychain helpers, identity adoption |
| `scripts/bump_build.sh` | Increments `CURRENT_PROJECT_VERSION` |
| `ExportOptions.plist` | Manual signing, upload destination, no Xcode-managed build numbers |
| `.deploy.env.example` | The credentials contract (the real file is gitignored) |

### Credentials

`.deploy.env`, gitignored, holds only identifiers and a local keychain
password:

```
ASC_KEY_ID=…                 # 10-char key id
ASC_ISSUER_ID=…              # team issuer UUID
SIGNING_KEYCHAIN_PASSWORD=…  # local only, never leaves this machine
```

The `.p8` private key stays in `~/.appstoreconnect/private_keys/` and is read
only by `asc.py`. It is never copied into the repo, echoed, or passed on a
command line.

### Checking readiness without building

```sh
scripts/deploy-testflight.sh --preflight    # is a headless deploy possible?
python3 scripts/lib/asc.py check            # what can the key see?
python3 scripts/lib/asc.py builds           # recent TestFlight builds
```

`--preflight` verifies the tools, the SAM 2 weights, the signing identity, the
profile and its expiry, and that the API key authenticates — and changes
nothing.

### Useful flags

```sh
scripts/deploy-testflight.sh --no-bump   # re-upload attempt, same number
scripts/deploy-testflight.sh --no-wait   # don't block on processing
```

## Steps only Ali can do, if they come up

**On the happy path, none.** The API key is Admin with Certificates,
Identifiers & Profiles access, which covers everything here.

### If the certificate expires (2027-08-21) or is revoked

Run `scripts/bootstrap_signing.sh --new-cert`. That mints a fresh certificate
and consumes one of the team's slots. If Apple refuses with a limit error, one
existing certificate must be revoked first, at
<https://developer.apple.com> → Account → Certificates, Identifiers & Profiles
→ Certificates. **Revoking invalidates every build signed with it**, across
both apps.

### If the API key is rotated

App Store Connect → Users and Access → Integrations → App Store Connect API.
Generate a key with the **Admin** role, download the `.p8` (Apple allows the
download **once**), place it at
`~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`, and update `ASC_KEY_ID`
in `.deploy.env`. The Issuer ID is shown at the top of that same page and is
the same for every key on the team.

### A new app record

The App Store Connect API cannot create app records (`apps does not allow
CREATE`) — that one screen is always a human step. Draw'n'Cut's already
exists: app id `6801907664`.

## Known constraints

- **Build numbers never repeat.** App Store Connect rejects a build whose
  `CFBundleVersion` is not higher than the last one. `deploy-testflight.sh`
  bumps before archiving; `--no-bump` will be rejected if that number was
  already uploaded.
- **The Mac must be powered on and logged in.** The dedicated keychain is
  unlocked by the script, so a locked *screen* is fine, but a logged-out or
  sleeping machine is not.
- **Processing lag is normal.** Uploads are usually accepted immediately but
  can take well over ten minutes to appear in the API. `wait-build` polls for
  30 minutes and says so rather than failing silently.
- **The SAM 2 weights are gitignored** (~90 MB). A fresh clone must run
  `scripts/download-models.sh` before archiving; preflight checks for them, so
  a build cannot silently ship without subject selection.

## Branches

Work happens on `dev`; `main` is kept stable and only moves when Ali says so.
