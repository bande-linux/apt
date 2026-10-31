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
| `apple` | arm64 | green scheduled or dispatched `follow-debian.yml` runs on `main` of `bande-linux/kernel` that built a kernel | `linux-*-apple-*`, `bande-os-apple` |

Each package keeps its newest version only, as in Debian's own suites. Kernel packages carry
the kernel version in their name, so `apple` keeps the packages of the newest two kernel
versions and drops older ones; kernel debs are large and the site must stay under the Pages
limit. The repository packages (`bande-archive-keyring`, `bande-apt-source`) live in `main`.

## How a publish works

[`publish.yml`](.github/workflows/publish.yml) runs every 30 minutes. The source repositories
need no publish step and no token for apt: they only upload their artifacts, and apt reads both
public repositories with its own `github.token`. Its only secret is `APT_SIGNING_KEY`.

0. [`scripts/find-runs.sh`](scripts/find-runs.sh) looks for runs newer than the live archive,
   whose signature it checks:
   - desktop: the green `release.yml` push of the highest `vX.Y.Z` tag, against the version of
     `bande-desktop` in `main`;
   - kernel: the newest green `follow-debian.yml` run on `main` that uploaded a
     `bande-version-VERSION` artifact (runs that found nothing new upload none), against the
     version of `bande-os-apple` in `apple`.

   With nothing new the workflow stops there: no rebuild, no deploy, and no use of the
   `apt-publish` environment. A desktop and a kernel release found together go out in one
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
   - its commit must be on `main`.

   It then downloads the `bande-debs-ARCH` artifacts. The desktop uploads `amd64`, `arm64`
   and `all`; the kernel uploads `arm64`. It refuses:
   - package names outside the repository's list;
   - a package filed under another architecture's artifact;
   - versions other than the run's: exactly the tag's `X.Y.Z` for the desktop, and for the
     kernel the version its one `bande-version-VERSION` artifact names, of the form
     `<debian-version>+bandeN`;
   - an incomplete architecture: one that lacks a package another architecture carries.
2. [`scripts/rebuild.sh`](scripts/rebuild.sh) rebuilds the whole archive with reprepro in a fresh
   database:
   - its input is the live site, whose `InRelease` signatures, `Packages` and pool checksums are
     all verified, plus the new packages of each run (`--add COMPONENT=DIR`, once per run);
   - a component or architecture that the live `Release` does not list yet starts empty;
   - on each architecture, the new packages (with the architecture-independent ones) must
     carry one version, the repository packages aside;
   - it refuses a version older than the live one and changed contents under a published
     version;
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

## First publish

The site holds no archive yet, so the first publish must say so; every later one refuses to run
without a live, signed `InRelease`. Until then, a scheduled run that finds a release fails at the
rebuild, so make the first publish once the first desktop tag is green:

1. Publish everything released so far:

   ```bash
   gh workflow run publish.yml -R bande-linux/apt -f initial=true
   ```

   Or publish one run, found with
   `gh run list -R bande-linux/desktop -w release.yml -e push -s success -L 5`:

   ```bash
   gh workflow run publish.yml -R bande-linux/apt -f repo=desktop -f run_id=RUN_ID -f initial=true
   ```

2. Check <https://bande-linux.github.io/apt/dists/rolling/InRelease> and the
   `apt-source-VERSION` release, then `apt install bande-desktop` in a fresh Debian testing
   on amd64 and arm64.

A kernel that arrives later needs no `initial`: it adds `apple` to the live archive.

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
