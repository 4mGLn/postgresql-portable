# Portable PostgreSQL Build

## Why This Exists

Enterprise and government environments often operate air-gapped networks — servers with no outbound internet access, strict package whitelisting, and no ability to run `apt`, `yum`, or any package manager against external repositories. Installing PostgreSQL on these hosts traditionally requires navigating complex internal approval workflows, mirroring entire distribution repositories, or manually resolving shared-library dependency chains.

This project eliminates that friction. It produces fully self-contained, relocatable PostgreSQL archives that can be copied onto any target machine via USB, SCP, or internal artifact storage and run immediately — no package manager, no root access, no internet connection required. Extract, source the environment helper, and you have a working PostgreSQL instance.

## Supported Platforms

This repository builds portable, relocatable PostgreSQL release archives for:

- `unknown-linux_x86_64` — CentOS 7+ / glibc 2.17+ (built on manylinux2014)
- `windows_x86_64` — Windows 10+ (MSYS2/MinGW-w64)

## Packaging Contract

The base package contains upstream PostgreSQL plus all contrib extensions (pgcrypto, postgres_fdw, hstore, etc.).

Third-party extensions are built and released as separate overlay archives:

- `pg_hint_plan`
- `pg_partman`
- `pg_cron`
- `pgvector`

Each overlay archive is intended to be extracted over the matching base package for the same PostgreSQL version and target.

## Linux Portability

The Linux build uses the `manylinux2014` container (CentOS 7 base, glibc 2.17) to maximize compatibility across distributions. ELF binaries are patched with `patchelf` to use `$ORIGIN`-relative RPATHs, making the archive relocatable without system-wide library installation.

## Supply-Chain Integrity

Source tarballs downloaded during the build are verified against upstream SHA256 checksums published by the PostgreSQL project. A checksum mismatch aborts the build immediately.

## Requirements

- **Bash 4+** (the build scripts use `mapfile` and associative arrays)
- **Docker or Podman** (for portable Linux builds via manylinux2014 container)
- Standard build tools: `gcc`, `make`, `perl`, `flex`, `bison`
- `patchelf` (Linux builds only, for RPATH normalization)
- `jq`, `curl`, `git`

## Main Files

- `ci/postgresql-release-config.json` — tracked majors, portable-build defaults, extension refs
- `ci/Dockerfile.manylinux2014` — pre-built Linux build container with all dependencies
- `scripts/ci/build_portable_postgresql.sh` — builds the base portable archive and contrib
- `scripts/ci/build_extension_overlay.sh` — builds separate third-party extension overlays
- `scripts/ci/bundle_runtime_deps.sh` — bundles shared libraries and normalizes RPATHs
- `scripts/run_local_build.sh` — local build wrapper (auto-containerized on Linux)
- `.github/workflows/release-and-publish.yml` — cross-platform CI build and release
- `.github/workflows/upstream-sync.yml` — syncs tracked PostgreSQL releases from upstream tags
- `.github/workflows/validate-config.yml` — PR validation for release config changes
- `.github/workflows/build-container.yml` — builds and pushes the Linux build container to GHCR

## Local Build

Build for the current host platform (Linux builds automatically run inside the manylinux2014 container):

```bash
scripts/run_local_build.sh --major 17
```

Build directly on the host without container (result is not portable across glibc versions):

```bash
scripts/run_local_build.sh --major 17 --no-container
```

Build for an explicit target:

```bash
scripts/ci/build_portable_postgresql.sh --major 17 --target unknown-linux_x86_64
```

## Automatic Upstream Sync

New PostgreSQL patch releases are picked up automatically:

1. **`upstream-sync.yml`** runs on the 1st and 15th of each month (or manually)
2. It discovers new release tags and updates `ci/postgresql-release-config.json`
3. A PR is created and auto-merge is requested
4. **`validate-config.yml`** runs on the PR to validate the config structure
5. Once the check passes, the PR auto-merges into `main`
6. **`release-and-publish.yml`** triggers and builds + publishes all platforms

## Bundled Features

The portable build includes full feature support with all required libraries bundled:

- **readline** — interactive `psql` line editing, history, and tab completion
- **zlib** — compressed `pg_dump` / `pg_restore` support
- **ICU** — locale-independent Unicode collation and character classification
- **LDAP** — LDAP authentication support in `pg_hba.conf` for enterprise directory integration
- **NLS** — translated server and client error messages (gettext)

These libraries are bundled into the archive and do not need to be installed on the target machine.

## CI Performance

The CI pipeline is optimized for fast subsequent runs:

- **Pre-built container** — Linux builds use a GHCR-hosted Docker image with all dependencies pre-installed, eliminating ~3 min of `yum install` per run
- **ccache** — compilation cache across all platforms with weekly key rotation, reducing recompilation to cache lookups (~60-70% faster)

First run: ~25 min. Subsequent cached runs: ~8-12 min.

## Known Limitations

- Linux binaries require a glibc >= 2.17 host (CentOS 7 era). Musl-based distributions (Alpine) are not supported.

## License

This build system is licensed under the [MIT License](LICENSE).

PostgreSQL itself is distributed under the [PostgreSQL License](https://www.postgresql.org/about/licence/), a permissive open-source license similar to BSD/MIT. Third-party extensions included as overlays are subject to their respective licenses.
