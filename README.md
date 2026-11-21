# Bande APT repository

The APT repository for the Bande desktop, served by GitHub Pages at
<https://bande-linux.github.io/apt>. This repository holds only the tooling that builds and
signs the published site. The site itself is deployed as a Pages artifact and is not stored in
git.

Install instructions for users are on the website at <https://bande-linux.github.io/debian/>. The
archive's own page ([`site/index.html`](site/index.html)) links there and shows the source stanza
and the key fingerprint, styled by the website's `/style.css`.

## The archive

One suite per Debian release, named by its codename. [`conf/suites`](conf/suites) lists them, one
per line, and is the only list: the source repositories read it from `main` to build their
matrix, and every publish rebuilds each suite it lists. Today it lists `forky` (Debian 14).
Each suite has one component, `main`, and the suites share one pool:

| Component | Architectures | Fed by | Names |
|---|---|---|---|
| `main` | amd64, arm64 | green `release.yml` runs of `vX.Y.Z` tag pushes of `bande-linux/desktop`, the tagged commit on `main` | `bande-*` (the desktop and every Bande app), `xdg-desktop-portal-bande`, `libpam-bande-secrets` |
| `main` | amd64, arm64 | green scheduled or dispatched `follow-debian.yml` runs on `main` of `bande-linux/web` that built the browser | `bande-browser`, `bande-browser-l10n-*` |
| `main` | all | green `l10n.yml` runs of `l10n-YYYYMMDD[.N]` tag pushes of `bande-linux/desktop`, the tagged commit on `main`: translation-only builds | `bande-desktop-l10n-*`, at `<release>+l10nYYYYMMDD[.N]` |
| `main` | all | green `dict.yml` runs of `dict-YYYYMMDD` tag pushes of `bande-linux/desktop`, the tagged commit on `main` | `bande-dict-*`, Dictionary's packs |

Each package keeps its newest version only, as in Debian's own suites.

### Suites and versions

Every package built for a suite carries `~debNN` right after its release version, NN being the
Debian version number (from distro-info-data's `debian.csv`; `forky` is 14), as Debian's
backports carry `~bpoNN+N`:

| Source | Version |
|---|---|
| desktop `vX.Y.Z` | `X.Y.Z~deb14` |
| `l10n-YYYYMMDD[.N]` packs | `X.Y.Z~deb14+l10nYYYYMMDD[.N]`, X.Y.Z the release they translate |
| dict `dict-YYYYMMDD` | `YYYYMMDD~deb14` |
| web (`bande-version-BASE`) | `BASE~deb14`, BASE `<debian-version>+bandeN` |
| `bande-apt-source` | `1.N~deb14`, one per suite |
| `bande-archive-keyring` | `1.N`, the same file for every suite |

`~` sorts below everything, so `X.Y.Z~deb14` is older than an unsuffixed `X.Y.Z`, and
`X.Y.Z~deb14` < `X.Y.Z~deb15`: a machine upgraded from forky to duke, its source switched to
`duke`, upgrades Bande too, even at the same release. Find-runs compares a tag with the live
versions without the suffix.

A source run uploads, for each suite it built, `bande-debs-<suite>-<arch>` artifacts (the
architectures below). A run without any artifact of a listed suite, such as one built before
the suite was added, leaves that suite as it is; it must carry at least one suite.

- **Adding a suite** (Debian 15 `duke`): add `duke` to `conf/suites` and push. The next publish
  starts `dists/duke` empty with the repository packages, and the next tags of the source
  repositories build for it. Its `debian:duke` image and distro-info-data must know it.
- **Dropping a suite** at its Debian EOL: delete its line. The next publish no longer builds
  it, so `dists/<suite>` and its pool files leave the site; machines on it get no more updates.
  Users move to the next suite by upgrading Debian and installing that suite's
  `bande-apt-source` (step 1 of the site).

## The repository packages

`bande-archive-keyring` (the keys of [`conf/archive-key.asc`](conf/archive-key.asc) and an APT
pin that lets the archive provide only `bande-*`, `xdg-desktop-portal-bande` and
`libpam-bande-secrets`) and, for each suite, `bande-apt-source` (`<suite> main`) are built by
this repository, from [`packaging/`](packaging), with
[`scripts/build-repository-packages.sh`](scripts/build-repository-packages.sh). No source
repository may publish them, so the archive depends on none of them.

- Their version is `1.N` (`1.N~debNN` for the source), where N counts the commits that touched
  `packaging/`, the keys, `conf/suites` or the build script. Change any of them and the next
  publish carries a new version; so a new suite gets its own.
- The same commit builds byte-identical packages. Every publish adds them to `main`, for every
  architecture; one already published at its version is kept.

Each package name belongs to one source: `apt`, `desktop` (its language packs included), `dict`
or `web`. The site keeps the owners in `state/owners`, and a publish refuses a name another
source already publishes. A name whose owner is not one of these sources is free: a source that
publishes it takes it, and otherwise it leaves the archive, as Debian drops the binaries a source
no longer builds.

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
   - apt: repository packages of a version newer than the live `bande-archive-keyring` of any
     suite (a suite not served yet has none);
   - desktop: the green `release.yml` push of the highest `vX.Y.Z` tag, against the version of
     `bande-desktop` in `main`;
   - dict: the green `dict.yml` push of the desktop's highest `dict-YYYYMMDD` tag, against the
     version of `bande-dict-en` in `main`;
   - web: the newest green `follow-debian.yml` run on `main` of `bande-linux/web` that uploaded
     a `bande-version-VERSION` artifact (runs that found nothing new upload none), against the
     version of `bande-browser` in `main`;
   - l10n: the green `l10n.yml` push of the desktop's highest `l10n-YYYYMMDD[.N]` tag, unless
     the live `state/processed` lists it (the publish records every one it took or refused). It
     waits while a `vX.Y.Z` tag on the run's history is newer than what `main` serves or this
     publish takes, since its packs are built on that release.

   - resign: a suite's live `InRelease` has its `Valid-Until` less than 7 days out, or none.
     Past it, only the re-sign is started.

   Each live version is the newest across the suites, without the suite's `~debNN`.

   With nothing new the workflow stops there: no rebuild, no deploy, and no use of the
   `apt-publish` environment. Releases of several repositories found together go out in one
   publish.

   Publishes share the `pages` concurrency group, so they run one at a time. GitHub keeps only
   the newest pending run of a group and cancels the one it replaces; that loses nothing, since
   the next look finds the same releases.

1. [`scripts/fetch-run.sh`](scripts/fetch-run.sh) checks the run:
   - it must come from the repository's release workflow and end in success (for a run given
     by hand it waits for the run to finish);
   - a desktop run must be the `push` of a `vX.Y.Z` tag that points at the run's commit; a
     desktop push to `main` is refused;
   - a web run must be a `schedule` or `workflow_dispatch` run on `main`;
   - a dict run must be the desktop's `dict.yml` `push` of a `dict-YYYYMMDD` tag that points
     at the run's commit; it carries `bande-dict-*` alone, at `YYYYMMDD`, in `all`;
   - an l10n run must be the desktop's `l10n.yml` `push` of an `l10n-YYYYMMDD[.N]` tag that
     points at the run's commit; it carries `bande-desktop-l10n-*` alone, in `all`, each at
     `<release>+l10n<stamp>` where the tag `v<release>` is on the run's history;
   - its commit must be on `main`.

   It then downloads, for each suite, the `bande-debs-<suite>-<arch>` artifacts into
   `<dir>/<suite>/`. The desktop uploads `amd64`, `arm64` and `all`, web `amd64`, `arm64` and
   `all` (the language packs), dict and l10n `all`. It refuses:
   - package names outside the repository's list, and the repository packages;
   - a package filed under another architecture's artifact;
   - versions other than the run's plus the suite's suffix (see [Suites and
     versions](#suites-and-versions)): the tag's `X.Y.Z~debNN` for the desktop, so
     test builds' `+git` versions are refused, and for web the version its one
     `bande-version-VERSION` artifact names, of the form `<debian-version>+bandeN`;
   - an incomplete architecture: one that lacks a package another architecture carries in that
     suite.

   A refused l10n run is recorded as taken and left out, so it cannot hold up the other
   releases; the publish then ends red, naming it.
2. [`scripts/rebuild.sh`](scripts/rebuild.sh) rebuilds the whole archive, every suite, with
   reprepro in a fresh database; [`conf/distribution.in`](conf/distribution.in) is each suite's
   stanza:
   - its input is the live site, whose `InRelease` signatures, `Packages` and pool checksums are
     all verified, plus the new packages, from `DIR/<suite>/`: `--add desktop:main=DIR` for
     a desktop build, `--add web:main=DIR` for the browser, `--add-each apt:main=DIR` for
     the repository packages;
   - a suite, component or architecture that the live site does not serve yet starts empty; a
     component the live site serves but `conf/distribution.in` no longer lists is dropped, with
     its pool files and its names in `state/owners`;
   - for a desktop or browser build, the new packages of a suite on each architecture (with the
     architecture-independent ones) must carry one version, and
     it refuses a version older than the live one and changed contents under a published
     version;
   - for the repository packages, each package stands alone: one whose version is already
     published, or older, is skipped and the published one kept;
   - for language packs (`--add-l10n desktop:main=DIR`), after every
     other addition, a pack at `<release>+l10n<stamp>` goes in only while the package it
     `Enhances` is at `<release>`: one built on an older release, or on one not published, is
     skipped, so a translation-only build never replaces a newer release's packs;
   - it refuses a source other than `apt`, `desktop`, `dict` and `web`, and a name that
     `state/owners` gives to another of them; a name `state/owners` gives to any other source
     goes to the source that publishes it now, or leaves the archive;
   - reprepro builds the pool and the `Packages` indexes; `apt-ftparchive release` writes each
     suite's `Release` with SHA256 sums, `Acquire-By-Hash: yes` and `Valid-Until` 14 days out, and copies every index to
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
If the re-signs keep failing until `Valid-Until` passes, the live `InRelease` expires and apt
clients refuse it. Look then takes no new runs from it, since an expired index could be a replay,
logs a warning and starts "Re-sign the archive"; `rebuild.sh` still requires the archive key's
signatures on it.

## Pages caching

Pages serves every file with `cache-control: max-age=600`, and its CDN caches each file on its
own. For up to ten minutes after a publish it can serve a new `InRelease` beside an old
`Packages.xz`, or the other way round. The archive therefore follows Debian's by-hash layout:

- `Release` carries `Acquire-By-Hash: yes`, and every index is also served at
  `dists/<suite>/<component>/binary-<arch>/by-hash/SHA256/<sha256>`. That path never changes
  content, so apt (and `find-runs.sh` and `rebuild.sh`) always get the index that the
  `InRelease` they hold names.
- Each by-hash directory keeps the newest 3 generations, so a client holding an `InRelease` from
  an earlier publish still finds its indexes. `rebuild.sh` prunes them itself, by mtime, since
  apt-ftparchive's `By-Hash-Keep` skips the first directory of a suite. Pages cannot list a
  directory and every publish builds the site afresh, so the site lists the by-hash files with
  their times in `state/by-hash`, and the next publish restores them from the live site before
  pruning.
- Files a publish replaces (`InRelease`, `key.asc`, `state/*`) are read with
  [`scripts/fetch-fresh.sh`](scripts/fetch-fresh.sh). The CDN ignores the query string, so
  `?nonce` does not get past it, but it keys on the literal path, which Pages decodes: the
  script percent-encodes a random set of the path's letters (never the `/apt` site root, which
  Pages routes before decoding) and refuses an answer with an `Age` above 0.

## Workflow

- **Access:** `github.token` with `actions: read` and `contents: read`; `desktop` and `web` are
  public, so no other token or GitHub App is involved.
- **Signing:** the signing subkey is a secret of the `apt-publish` environment, which only `main`
  can use.
- **Deploy:** the site is deployed with `actions/deploy-pages`.
- **Bootstrap release:** when the repository packages reach a new version,
  [`scripts/bootstrap-release.sh`](scripts/bootstrap-release.sh) creates the GitHub release
  `apt-source-VERSION`, which users download in the first install step:
  `bande-archive-keyring.deb` and `bande-apt-source-<suite>.deb`.
- **Verify:** after each deploy, for each suite, a `debian:<suite>` container on amd64 and on
  arm64 checks that the live `key.asc` is the archive key, installs `bande-archive-keyring` and
  `bande-apt-source` from that suite, and updates through the source they install. When the
  suite carries a desktop, it waits until the site serves the version the build job put in, installs
  `bande-desktop`, checks that every installed `bande-*` package is built for the machine's
  architecture (or `all`) at that version, and starts the installed compositor headless. It
  warns about any package `bande-desktop` recommends that neither the archive nor that Debian
  release has.

## First publish

Nothing special: the first publish can come from any source, or from the repository packages
alone. A site that serves no suite's `InRelease` nor `key.asc` has never been published, and
[`scripts/rebuild.sh`](scripts/rebuild.sh) starts the archive. A site that serves `key.asc` but
no suite's `InRelease` is broken, and the publish refuses to build over it.

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
API over local HTTP, and check finding new releases, every source repository, dropping a
component, tampering and forged signatures, and a stale `Packages.xz` beside a new
`InRelease`, which both the scripts and apt resolve by hash. They also check rotation, and that apt itself
updates from and downloads out of the result, without touching the machine's own apt state.
