# Unbound APT repository

The APT repository for the Unbound desktop, served by GitHub Pages at
<https://unbound-linux.github.io/apt>. This repository holds only the tooling that builds and
signs the published site. The site itself is deployed as a Pages artifact and is not stored in
git.

Install instructions for users are on the site ([`site/index.html`](site/index.html)).

## Channels

| Channel | Suite | Fed by |
|---|---|---|
| release | `trixie` | `vX.Y.Z` tags of `unbound-linux/desktop`: the green `main` build of the tagged commit, promoted to `X.Y.Z` |
| testing | `trixie-testing` | every green push to `main` of `unbound-linux/desktop` |

Each suite carries one version of each package: the newest, as in Debian's own suites. The
repository packages (`unbound-archive-keyring`, `unbound-apt-source`,
`unbound-apt-source-testing`) are published to both suites.

## How a publish works

1. [`scripts/fetch-run.sh`](scripts/fetch-run.sh) checks a desktop CI run:
   - it must be a push to `main`, or the run of a `vX.Y.Z` tag;
   - every other job must be green and the commit must be on `main`;
   - for a tag, `Cargo.toml` must declare the tag's version.

   It then downloads the `unbound-debs-*` artifacts. For a release it promotes the `main`
   packages to the tag's version with [`scripts/promote.sh`](scripts/promote.sh), which changes
   only their control files.
2. [`scripts/rebuild.sh`](scripts/rebuild.sh) rebuilds the whole archive with reprepro in a fresh
   database:
   - its input is the live site, whose `InRelease` signatures, `Packages` and pool checksums are
     all verified, plus the new packages;
   - it refuses a version older than the live one and refuses changed contents under a
     published version;
   - it signs with every key in [`conf/signing-keys`](conf/signing-keys).
3. [`scripts/check-site.sh`](scripts/check-site.sh) checks the result before deploying:
   signatures, checksums, no unlisted pool files, no file over 95 MB, and the site under 800 MB.

No state is kept between runs: the live site is the source of truth.

[`publish.yml`](.github/workflows/publish.yml) runs these steps. The last job of desktop's CI
starts it with the run id, and with the tag for a release.
- **Release publishes** wait for approval in the `apt-stable-approval` environment.
- **Signing:** the signing subkey is a secret of the `apt-publish` environment, which only `main`
  can use.
- **Deploy:** the site is deployed with `actions/deploy-pages`.
- **Bootstrap release:** when the repository packages reach a new version,
  [`scripts/bootstrap-release.sh`](scripts/bootstrap-release.sh) creates the GitHub release
  `apt-source-VERSION`, which users download in the first install step.

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

```bash
docker run --rm -v "$PWD":/apt -w /apt debian:trixie \
    sh -c 'apt-get update -qq && xargs apt-get install -y -qq --no-install-recommends < ci/packages && tests/run-all.sh'
```

The tests build throwaway keys and packages, serve sites over local HTTP, and check publishing,
promotion, tampering and forged signatures. They also check rotation, and that apt itself
updates from and installs out of the result.
