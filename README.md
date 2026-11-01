# Bande APT repository

The APT repository for the Bande desktop, served by GitHub Pages at
<https://bande-linux.github.io/apt>. This repository holds only the tooling that builds and
signs the published site. The site itself is deployed as a Pages artifact and is not stored in
git.

Install instructions for users are on the site ([`site/index.html`](site/index.html)).

## The archive

One suite, `rolling`, for Debian testing:

| Component | Architectures | Fed by | Names |
|---|---|---|---|
| `main` | amd64, arm64 | green `release.yml` runs of `vX.Y.Z` tag pushes of `bande-linux/desktop`, the tagged commit on `main` | `bande-*`, `xdg-desktop-portal-bande` |
| `main` | amd64, arm64 | green `build.yml` runs of `<app>-vX.Y.Z` tag pushes of `bande-linux/apps`, the tagged commit on `main`, one app per tag | `bande-<app>` for each `apps/<app>`: Terminal, Software and the Package Installer (recommended by `bande-desktop`), Mail, Calendar |
| `apple` | arm64 | green scheduled or dispatched `follow-debian.yml` runs on `main` of `bande-linux/kernel` that built a kernel | `linux-*-apple-*`, `bande-os-apple` |

Each package keeps its newest version only, as in Debian's own suites. Kernel packages carry
the kernel version in their name, so `apple` keeps the packages of the newest two kernel
versions and drops older ones; kernel debs are large and the site must stay under the Pages
limit.

## The repository packages

`bande-archive-keyring` (the keys of [`conf/archive-key.asc`](conf/archive-key.asc) and an APT
pin that lets the archive provide only `bande-*`, `xdg-desktop-portal-bande` and
`linux-*-apple-*`) and `bande-apt-source` (`rolling main apple`) are built by this repository,
from [`packaging/`](packaging), with
[`scripts/build-repository-packages.sh`](scripts/build-repository-packages.sh). No source
repository may publish them, so the archive depends on none of them.

- Their version is `1.N`, where N counts the commits that touched `packaging/`, the keys or the
  build script. Change any of them and the next publish carries a new version.
- The same commit builds byte-identical packages. Every publish adds them to `main`, for every
  architecture; one already published at its version is kept.

Each package name belongs to one source repository. The site keeps the owners in
`state/owners`, and a publish refuses a name another source already publishes. An app can never
take a name the desktop publishes.

## How a publish works

[`publish.yml`](.github/workflows/publish.yml) runs every 30 minutes. The source repositories
need no publish step and no token for apt: they only upload their artifacts, and apt reads the
public repositories with its own `github.token`. Its only secret is `APT_SIGNING_KEY`.

0. [`scripts/find-runs.sh`](scripts/find-runs.sh) looks for runs newer than the live archive,
   whose signature it checks. A source repository that does not exist yet, or has no green run,
   is nothing new:
   - apt: repository packages of a version newer than the live `bande-archive-keyring`;
   - desktop: the green `release.yml` push of the highest `vX.Y.Z` tag, against the version of
     `bande-desktop` in `main`;
   - kernel: the newest green `follow-debian.yml` run on `main` that uploaded a
     `bande-version-VERSION` artifact (runs that found nothing new upload none), against the
     version of `bande-os-apple` in `apple`;
   - apps: for each app, the green `build.yml` push of its highest `<app>-vX.Y.Z` tag, against
     the version of `bande-<app>` in `main`, unless the live `state/processed` lists the run:
     the publish records every apps run it took or refused there, so a refused tag is not
     tried again until the app tags a newer version.

   With nothing new the workflow stops there: no rebuild, no deploy, and no use of the
   `apt-publish` environment. Releases of several repositories found together go out in one
   publish.

A dispatch with `repo` and `run_id` publishes that run instead of searching. Publishes share
the `pages` concurrency group, so they run one at a time. GitHub keeps only the newest pending
run of a group and cancels the one it replaces; that loses nothing, since the next run finds the
same releases.

1. [`scripts/fetch-run.sh`](scripts/fetch-run.sh) checks the run:
   - it must come from the repository's release workflow and end in success (for a run given
     by hand it waits for the run to finish);
   - a desktop run must be the `push` of a `vX.Y.Z` tag that points at the run's commit; a
     desktop push to `main` is refused;
   - a kernel run must be a `schedule` or `workflow_dispatch` run on `main`;
   - an apps run must be the `push` of an `<app>-vX.Y.Z` tag that points at the run's commit,
     for an `apps/<app>` at that commit; dispatch runs are test builds and branch runs, such as
     the `ci-test` run of `bande-template`, are never published;
   - its commit must be on `main`.

   It then downloads the `bande-debs-ARCH` artifacts. The desktop uploads `amd64`, `arm64`
   and `all`, the kernel `arm64`, and apps `amd64` and `arm64`. It refuses:
   - package names outside the repository's list; for apps, exactly `bande-<app>` of the tag,
     and never a name of the desktop's (its `packaging/`
     directories, `bande-desktop`, `xdg-desktop-portal-bande`, the repository
     packages);
   - a package filed under another architecture's artifact;
   - versions other than the run's: exactly the tag's `X.Y.Z` for the desktop, and for the
     kernel the version its one `bande-version-VERSION` artifact names, of the form
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
     build, `--add-each apps:main=DIR` for apps;
   - a component or architecture that the live `Release` does not list yet starts empty;
   - for a desktop or kernel build, the new packages on each architecture (with the
     architecture-independent ones) must carry one version, and
     it refuses a version older than the live one and changed contents under a published
     version;
   - for apps, each package stands alone: one whose version is already published, or older, is
     skipped and the published one kept;
   - it refuses a name that `state/owners` gives to another source;
   - it signs with every key in [`conf/signing-keys`](conf/signing-keys).
3. [`scripts/check-site.sh`](scripts/check-site.sh) checks the result before deploying:
   signatures, checksums, no unlisted pool files, no file over 95 MB, and the site under 800 MB
   (a warning over 600 MB).

No state is kept between runs: the live site is the source of truth.

- **Access:** `github.token` with `actions: read` and `contents: read`; `desktop` and `kernel`
  are public, so no other token or GitHub App is involved.
- **Signing:** the signing subkey is a secret of the `apt-publish` environment, which only `main`
  can use.
- **Deploy:** the site is deployed with `actions/deploy-pages`.
- **Bootstrap release:** when the repository packages reach a new version,
  [`scripts/bootstrap-release.sh`](scripts/bootstrap-release.sh) creates the GitHub release
  `apt-source-VERSION`, which users download in the first install step.
- **Verify:** after each deploy, a `debian:testing` container on amd64 and on arm64 checks that
  the live `key.asc` is the archive key, installs `bande-archive-keyring` and `bande-apt-source`
  from the live archive, and updates through the source they install. When the archive
  carries a desktop, it waits until the site serves the version the build job put in, installs
  `bande-desktop`, checks that every installed `bande-*` package is built for the machine's
  architecture (or `all`) at that version, and starts the installed compositor headless. It
  warns about any package `bande-desktop` recommends that neither the archive nor Debian testing
  has, such as a default app from `bande-linux/apps` that has not been released yet.

## First publish

Nothing special: the first publish can come from any source, or from the repository packages
alone. A site that serves neither `dists/rolling/InRelease` nor `key.asc` has never been
published, and [`scripts/rebuild.sh`](scripts/rebuild.sh) starts the archive. A site that
serves `key.asc` but no `InRelease` is broken, and the publish refuses to build over it.

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
subkeys run out.

## Testing locally

On Debian, as root install the tools, then run the tests as any user:

```bash
sudo sh -c 'xargs apt-get install -y -qq --no-install-recommends < ci/packages'
```

```bash
tests/run-all.sh
```

The tests build throwaway keys and packages for amd64 and arm64, serve sites and a fake GitHub
API over local HTTP, and check finding new releases, both source repositories, publishing to both components, the
kernel limit, tampering and forged signatures. They also check rotation, and that apt itself
updates from and downloads out of the result, without touching the machine's own apt state.
