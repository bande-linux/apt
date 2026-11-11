# Bande APT repository

The APT repository for the Bande desktop, served by GitHub Pages at
<https://bande-linux.github.io/apt>. This repository holds only the tooling that builds and
signs the published site. The site itself is deployed as a Pages artifact and is not stored in
git.

Install instructions for users are on the site ([`site/index.html`](site/index.html)).

## The archive

One suite, `forky`, for Debian 14 (forky):

| Component | Architectures | Fed by | Names |
|---|---|---|---|
| `main` | amd64, arm64 | green `release.yml` runs of `vX.Y.Z` tag pushes of `bande-linux/desktop`, the tagged commit on `main` | `bande-*`, `xdg-desktop-portal-bande`, `libpam-bande-secrets` |
| `main` | amd64, arm64 | green `build.yml` runs of `<app>-vX.Y.Z` tag pushes of `bande-linux/apps`, the tagged commit on `main`, one app per tag | `bande-<app>` for each `apps/<app>`, with its language packs `bande-<app>-l10n-*`: Terminal, Software, the Package Installer and Activity Monitor (recommended by `bande-desktop`), Mail, Calendar |
| `main` | amd64, arm64 | green scheduled or dispatched `follow-debian.yml` runs on `main` of `bande-linux/web` that built the browser | `bande-browser`, `bande-browser-l10n-*` |
| `main` | all | green `l10n.yml` runs of `l10n-YYYYMMDD[.N]` tag pushes of `bande-linux/desktop` and of `bande-linux/apps`, the tagged commit on `main`: translation-only builds | `bande-desktop-l10n-*`, `bande-<app>-l10n-*`, each at `<release>+l10nYYYYMMDD[.N]` |
| `main` | all | green `dict.yml` runs of `dict-YYYYMMDD` tag pushes of `bande-linux/desktop`, the tagged commit on `main` | `bande-dict-*`, Dictionary's packs |
| `apple` | arm64 | green scheduled or dispatched `follow-debian.yml` runs on `main` of `bande-linux/kernel` that built a kernel | `linux-*-apple-*`, `bande-os-apple` |

Each package keeps its newest version only, as in Debian's own suites. Kernel packages carry
the kernel version in their name, so `apple` keeps the packages of the newest two kernel
versions and drops older ones; kernel debs are large and the site must stay under the Pages
limit.

## The repository packages

`bande-archive-keyring` (the keys of [`conf/archive-key.asc`](conf/archive-key.asc) and an APT
pin that lets the archive provide only `bande-*`, `xdg-desktop-portal-bande`, `libpam-bande-secrets` and
`linux-*-apple-*`) and `bande-apt-source` (`forky main`; its postinst adds `apple` in
`bande-apple.sources` on Apple Silicon) are built by this repository,
from [`packaging/`](packaging), with
[`scripts/build-repository-packages.sh`](scripts/build-repository-packages.sh). No source
repository may publish them, so the archive depends on none of them.

- Their version is `1.N`, where N counts the commits that touched `packaging/`, the keys or the
  build script. Change any of them and the next publish carries a new version.
- The same commit builds byte-identical packages. Every publish adds them to `main`, for every
  architecture; one already published at its version is kept.

Each package name belongs to one source repository. The site keeps the owners in
`state/owners`, and a publish refuses a name another source already publishes. An app can never
take a name the desktop publishes. [`conf/handovers`](conf/handovers) moves a name from one source
to another: `bande-browser` went from the apps' own engine to the Firefox-based build of the web
repository.

## How a publish works

[`look.yml`](.github/workflows/look.yml) ("look for releases") runs every 30 minutes and from its
Run workflow button. When it finds something new it starts [`publish.yml`](.github/workflows/publish.yml)
through a repository dispatch (publish has no button of its own), named after what it publishes, and deletes its own earlier green runs.
It also starts one, named "Re-sign the archive", when the live `InRelease` has fewer than 7
days left before its `Valid-Until`, or none (see [Valid-Until](#valid-until)). The source repositories
need no publish step and no token for apt: they only upload their artifacts, and apt reads the
public repositories with its own `github.token`. Its only secret is `APT_SIGNING_KEY`.

0. [`scripts/find-runs.sh`](scripts/find-runs.sh) looks for runs newer than the live archive,
   whose signature it checks; it reads the live site as described in
   [Pages caching](#pages-caching). A source repository that does not exist yet, or has no green run,
   is nothing new:
   - apt: repository packages of a version newer than the live `bande-archive-keyring`;
   - desktop: the green `release.yml` push of the highest `vX.Y.Z` tag, against the version of
     `bande-desktop` in `main`;
   - dict: the green `dict.yml` push of the desktop's highest `dict-YYYYMMDD` tag, against the
     version of `bande-dict-en` in `main`;
   - kernel: the newest green `follow-debian.yml` run on `main` that uploaded a
     `bande-version-VERSION` artifact (runs that found nothing new upload none), against the
     version of `bande-os-apple` in `apple`;
   - web: the same for `bande-linux/web`, against the version of `bande-browser` in `main`;
   - apps: for each app, the green `build.yml` push of its highest `<app>-vX.Y.Z` tag, against
     the version of `bande-<app>` in `main`, unless the live `state/processed` lists the run:
     the publish records every apps run it took or refused there, so a refused tag is not
     tried again until the app tags a newer version.

   - l10n and apps-l10n: the green `l10n.yml` push of the highest `l10n-YYYYMMDD[.N]` tag of the
     desktop and of the apps, unless `state/processed` lists it (the publish records every one
     it took or refused). It waits while a release tag on the run's history (`vX.Y.Z`, or an
     app's `<app>-vX.Y.Z`) is newer than what `main` serves or this publish takes, since its
     packs are built on that release.

   - resign: the live `InRelease`'s `Valid-Until` is less than 7 days out, or missing. Past
     it, only the re-sign is started.

   With nothing new the workflow stops there: no rebuild, no deploy, and no use of the
   `apt-publish` environment. Releases of several repositories found together go out in one
   publish.

Publishes share
the `pages` concurrency group, so they run one at a time. GitHub keeps only the newest pending
run of a group and cancels the one it replaces; that loses nothing, since the next look finds the
same releases.

1. [`scripts/fetch-run.sh`](scripts/fetch-run.sh) checks the run:
   - it must come from the repository's release workflow and end in success (for a run given
     by hand it waits for the run to finish);
   - a desktop run must be the `push` of a `vX.Y.Z` tag that points at the run's commit; a
     desktop push to `main` is refused;
   - a kernel or web run must be a `schedule` or `workflow_dispatch` run on `main`;
   - a dict run must be the desktop's `dict.yml` `push` of a `dict-YYYYMMDD` tag that points
     at the run's commit; it carries `bande-dict-*` alone, at `YYYYMMDD`, in `all`;
   - an apps run must be the `push` of an `<app>-vX.Y.Z` tag that points at the run's commit,
     for an `apps/<app>` at that commit; dispatch runs are test builds and are never published;
   - an l10n or apps-l10n run must be the `l10n.yml` `push` of an `l10n-YYYYMMDD[.N]` tag that
     points at the run's commit; it carries packs alone (`bande-desktop-l10n-*`, or
     `bande-<app>-l10n-*` for an `apps/<app>` at that commit, never a desktop name), in `all`,
     each at `<release>+l10n<stamp>` where the release tag (`v<release>`, `<app>-v<release>`) is on
     the run's history;
   - its commit must be on `main`.

   It then downloads the `bande-debs-ARCH` artifacts. The desktop uploads `amd64`, `arm64`
   and `all`, the kernel `arm64`, web `amd64`, `arm64` and `all` (the language packs), and apps
   `amd64` and `arm64`. It refuses:
   - package names outside the repository's list; for apps, exactly `bande-<app>` of the tag
     and its packs `bande-<app>-l10n-*` (architecture `all`, in each architecture's artifact),
     and never a name of the desktop's (its `packaging/`
     directories, `bande-desktop`, `xdg-desktop-portal-bande`, the repository
     packages);
   - a package filed under another architecture's artifact;
   - versions other than the run's: exactly the tag's `X.Y.Z` for the desktop, and for the
     kernel and web the version its one `bande-version-VERSION` artifact names, of the form
     `<debian-version>+bandeN`; for an app exactly its tag's `X.Y.Z`, so test builds'
     `+git` versions are refused;
   - an incomplete architecture: one that lacks a package another architecture carries.

   Several apps runs merge into one directory, keeping each app's newest version. A refused
   apps run is recorded as taken and left out, so it cannot hold up the other releases; the
   publish then ends red, naming it.
2. [`scripts/rebuild.sh`](scripts/rebuild.sh) rebuilds the whole archive with reprepro in a fresh
   database:
   - its input is the live site, whose `InRelease` signatures, `Packages` and pool checksums are
     all verified, plus the new packages: `--add SOURCE:COMPONENT=DIR` for a desktop or kernel
     build, `--add web:main=DIR` for the browser, `--add-each apps:main=DIR` for apps;
   - a component or architecture that the live `Release` does not list yet starts empty;
   - for a desktop or kernel build, the new packages on each architecture (with the
     architecture-independent ones) must carry one version, and
     it refuses a version older than the live one and changed contents under a published
     version;
   - for apps, each package stands alone: one whose version is already published, or older, is
     skipped and the published one kept;
   - for language packs (`--add-l10n desktop:main=DIR`, `--add-l10n apps:main=DIR`), after every
     other addition, a pack at `<release>+l10n<stamp>` goes in only while the package it
     `Enhances` is at `<release>`: one built on an older release, or on one not published, is
     skipped, so a translation-only build never replaces a newer release's packs;
   - it refuses a name that `state/owners` gives to another source;
   - reprepro builds the pool and the `Packages` indexes; `apt-ftparchive release` writes
     `Release` with SHA256 sums, `Acquire-By-Hash: yes` and `Valid-Until` 14 days out, and copies every index to
     `by-hash/SHA256/<sha256>` beside it (see [Pages caching](#pages-caching));
   - it signs `Release` as `InRelease` and `Release.gpg` with every key in
     [`conf/signing-keys`](conf/signing-keys).
3. [`scripts/check-site.sh`](scripts/check-site.sh) checks the result before deploying:
   signatures, checksums, a `Valid-Until` in the future and at most 14 days out, `Acquire-By-Hash` with every index served by hash and every by-hash
   file matching its name, no unlisted pool files, no file over 95 MB, and the site under 800 MB
   (a warning over 600 MB).

No state is kept between runs: the live site is the source of truth.

## Valid-Until

apt refuses an `InRelease` past its `Valid-Until`, so a mirror or attacker cannot keep serving an
old, validly signed archive that hides newer packages. Debian's own suites and the security
archive are valid for 7 days and re-signed every few hours; this archive changes less often, so
it is valid for 14 days (`APT::FTPArchive::Release::ValidTime` in `rebuild.sh`) and look re-signs
it once fewer than 7 days remain, about once a week. A re-sign is an ordinary publish with
nothing new: it rebuilds, signs, keeps the by-hash generations and verifies as any other.
If the re-signs keep failing until it passes, the live `InRelease` expires and apt clients refuse it. Look
then takes no new runs from it, since an expired index could be a replay, logs a warning and
starts "Re-sign the archive"; `rebuild.sh` still requires the archive key's signatures on it.

## Pages caching

Pages serves every file with `cache-control: max-age=600`, and its CDN caches each file on its
own. For up to ten minutes after a publish it can serve a new `InRelease` beside an old
`Packages.xz`, or the other way round. The archive therefore follows Debian's by-hash layout:

- `Release` carries `Acquire-By-Hash: yes`, and every index is also served at
  `dists/forky/<component>/binary-<arch>/by-hash/SHA256/<sha256>`. That path never changes
  content, so apt (and `find-runs.sh` and `rebuild.sh`) always get the index that the
  `InRelease` they hold names.
- apt-ftparchive keeps the newest 3 generations (`By-Hash-Keep`) in each by-hash directory, so a
  client holding an `InRelease` from an earlier publish still finds its indexes. Pages cannot
  list a directory and every publish builds the site afresh, so the site lists the by-hash files
  with their times in `state/by-hash`, and the next publish restores them from the live site
  before apt-ftparchive prunes.
- Files a publish replaces (`InRelease`, `key.asc`, `state/*`) are read with
  [`scripts/fetch-fresh.sh`](scripts/fetch-fresh.sh). The CDN ignores the query string, so
  `?nonce` does not get past it, but it keys on the literal path, which Pages decodes: the
  script percent-encodes a random set of the path's letters (never the `/apt` site root, which
  Pages routes before decoding) and refuses an answer with an `Age` above 0.

- **Access:** `github.token` with `actions: read` and `contents: read`; `desktop`, `kernel` and
  `apps` are public, so no other token or GitHub App is involved.
- **Signing:** the signing subkey is a secret of the `apt-publish` environment, which only `main`
  can use.
- **Deploy:** the site is deployed with `actions/deploy-pages`.
- **Bootstrap release:** when the repository packages reach a new version,
  [`scripts/bootstrap-release.sh`](scripts/bootstrap-release.sh) creates the GitHub release
  `apt-source-VERSION`, which users download in the first install step.
- **Verify:** after each deploy, a `debian:forky` container on amd64 and on arm64 checks that
  the live `key.asc` is the archive key, installs `bande-archive-keyring` and `bande-apt-source`
  from the live archive, and updates through the source they install. When the archive
  carries a desktop, it waits until the site serves the version the build job put in, installs
  `bande-desktop`, checks that every installed `bande-*` package is built for the machine's
  architecture (or `all`) at that version, and starts the installed compositor headless. It
  warns about any package `bande-desktop` recommends that neither the archive nor Debian forky
  has, such as a default app from `bande-linux/apps` that has not been released yet.

## First publish

Nothing special: the first publish can come from any source, or from the repository packages
alone. A site that serves neither `dists/forky/InRelease` nor `key.asc` has never been
published, and [`scripts/rebuild.sh`](scripts/rebuild.sh) starts the archive. A site that
serves `key.asc` but no `InRelease` is broken, and the publish refuses to build over it.

## A new suite

The suite is named after the Debian release it is built for (now `forky`, Debian 14). For the
next one, set `Codename` and `Suite` in [`conf/distributions`](conf/distributions), the source
in [`packaging/`](packaging), and name the old suite in `conf/previous-suite`: until the live
site serves the new suite, a publish reads the archive from the old one and publishes it under
the new name. Delete `conf/previous-suite` after that first publish.

## Signing keys

[`conf/archive-key.asc`](conf/archive-key.asc) holds the public archive key or keys.
[`conf/signing-keys`](conf/signing-keys) lists the primary fingerprints that sign. Which subkey
signs is decided by the secret subkey held in the `apt-publish` environment.

- **Rotating a signing subkey:**
  1. Publish a keyring that contains the new subkey.
  2. Wait for the overlap period.
  3. Replace the secret in the environment with the new subkey.
- **Rotating the primary key:** list both fingerprints in `signing-keys` during the overlap.
  Every index then carries both signatures, and clients holding either key accept it.

[`scripts/check-key-expiry.sh`](scripts/check-key-expiry.sh) fails 120 days before the signing
subkeys run out. Every publish runs it, with the tests below, before it signs anything.

## Testing locally

On Debian, as root install the tools, then run the tests as any user:

```bash
sudo sh -c 'xargs apt-get install -y -qq --no-install-recommends < ci/packages'
```

```bash
tests/run-all.sh
```

The tests build throwaway keys and packages for amd64 and arm64, serve sites and a fake GitHub
API over local HTTP, and check finding new releases, every source repository, publishing to both components, the
kernel limit, tampering and forged signatures, and a stale `Packages.xz` beside a new
`InRelease`, which both the scripts and apt resolve by hash. They also check rotation, and that apt itself
updates from and downloads out of the result, without touching the machine's own apt state.
