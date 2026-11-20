# Changelog

## Unreleased

### Added

- Track PostgreSQL 19, starting with 19.0 (`REL_19_0`), in Linux and Windows
  release builds and automatic upstream patch synchronization.
- Pin the PostgreSQL 19 `pg_hint_plan` overlay to `REL19_1_9_0`.
- Use `pg_cron` v1.6.8 for PostgreSQL 19 compatibility.
- Use `pgvector` v0.8.7 for PostgreSQL 19 builds.
- Document PostgreSQL 19 builds, release dispatch, and archive names.

### Fixed

- Pass an explicit Windows `nm.exe` path to configure for PostgreSQL 19's
  libpq sanity check under native UCRT Perl.
