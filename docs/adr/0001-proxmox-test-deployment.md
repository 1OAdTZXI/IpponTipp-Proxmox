# ADR-0001: Proxmox internal test deployment

- Status: Accepted
- Date: 2026-08-08

## Context

IpponTipp needs a repeatable, Community Scripts-style installation on a local
Proxmox host. The application source repository is private. Release-candidate
and production-like testing must remain isolated, updates must be manual, and
an existing reverse proxy may optionally provide the browser-facing URL and
TLS.

This deployment package is published independently from the application. It
consumes the application's repository layout, build files, settings, process
entry points, migrations, and health endpoint. The application has no dependency
on this package.

## Decision

1. Publish the contents of `deploy/proxmox/` as the root of a small public
   bootstrap repository. Keep application source and credentials private.
2. Create one unprivileged Debian 13 LXC with local Nginx, MariaDB, Redis, and
   systemd services per deployment channel. RC and production-like testing use
   separate containers and databases.
3. Ask for a fine-grained, repository-scoped read token on first execution and
   store it in a root-only environment file.
4. Deploy manually from exact tags. RC accepts
   `releases/MAJOR.MINOR.PATCH-rc.CANDIDATE`; production accepts
   `releases/MAJOR.MINOR.PATCH`. Select the highest SemVer-compatible core
   version and RC number, and reject a tag whose commit is not reachable from
   `master`. Ignore legacy tags and do not fall back to a branch or another
   channel.
5. Build locked dependencies from Debian's system Python in a relocatable
   environment plus static assets in a new release directory. Validate that the
   runtime is executable by the application service user before applying
   migrations. Discard and rebuild cached releases that fail this validation.
   Switch the active code symlink, restart Gunicorn and Celery services, and
   require every application service plus the database-aware health endpoint to
   remain healthy.
6. Serve plain HTTP directly in the isolated LAN by default. When configured,
   trust forwarded scheme and host information from an existing reverse proxy;
   TLS remains outside the LXC.
7. Keep persistence on each LXC root disk. Updates preserve database,
   configuration, runtime state, and prior release directories. Backups and
   recovery objectives are outside this test deployment.

## Consequences and known limitations

- The private source and secrets do not need to be published with the bootstrap.
- RC cannot promote data or code into production implicitly; promotion requires
  a separate production tag on a `master` commit.
- The bootstrap repository must be versioned and released independently.
- The token is simple for two local LXCs but requires manual expiry and rotation.
- A failed service start or runtime check can restore the previous code
  symlink, but applied database migrations are not automatically reversed.
- The package assumes Nginx, MariaDB, Redis, systemd, and the current application
  repository layout. It is not a universal hosting adapter.
- Script syntax, release selection, staging cleanup, and updater rollback paths
  are tested, but template discovery, storage, networking, package installation,
  and real service startup still require an end-to-end acceptance run on the
  target Proxmox host.

## Alternatives considered

- **Fetch the bootstrap from the private repository:** rejected because the
  installer could not start before credentials were provided.
- **Deploy the current `master` branch:** rejected because it is mutable and
  gives neither channel an auditable release identity.
- **Share one container between channels:** rejected because application state,
  credentials, and operational failures would no longer be isolated.
- **Treat this topology as universal:** rejected because other hosting platforms
  use different process, database, edge, and persistence primitives.
