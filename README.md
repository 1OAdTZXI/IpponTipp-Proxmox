# IpponTipp on Proxmox VE

This package provides a Community Scripts-style installation flow for an
internal IpponTipp test environment. It creates one unprivileged Debian 13 LXC
and installs the application and its local services. Create separate containers
for `release-candidate` and `production`; they do not share data or secrets.

The contents of `deploy/proxmox/` form the complete source of the separate
public `IpponTipp-Proxmox` repository. The application does not import or invoke
this package. The dependency points in the other direction: this package knows
the private application's repository layout, environment contract, process
entry points, migrations, and health endpoint. Future deployment adapters can
use separate directories without changing this package boundary.

The package is designed for Proxmox VE 9 or newer on AMD64. Its host script has
not yet been exercised against a real Proxmox host from this repository's test
environment, so the first installation should be treated as an acceptance test.
The rationale and operational trade-offs are recorded in
[`docs/adr/0001-proxmox-test-deployment.md`](docs/adr/0001-proxmox-test-deployment.md).

## Deployment model

```text
browser or optional existing reverse proxy
                  |
             LXC port 80
                  |
               Nginx
                  |
       Gunicorn / Django / Vue SPA
             |             |
          MariaDB       Redis
                          |
                   Celery Beat + Worker
```

There is no Cron job. Celery Beat schedules `event.sync_competitions` every 30
minutes, Redis transports the task, and a Celery Worker executes it. A file lock
prevents overlapping synchronization runs.

## Release contract

The updater considers exact, case-sensitive tag names only:

| Channel | Accepted tag | Example |
|---|---|---|
| `release-candidate` | `releases/MAJOR.MINOR.PATCH-rc.CANDIDATE` | `releases/1.0.0-rc.1` |
| `production` | `releases/MAJOR.MINOR.PATCH` | `releases/1.0.0` |

Core versions and RC numbers are ordered numerically, so `1.10.0-rc.2` is newer
than `1.9.0-rc.20`, and `1.0.0-rc.10` is newer than `1.0.0-rc.2`.
`release/*`, `releases/rc*`, `RELEASE-*`, branches, malformed versions, and the other
channel's tags are ignored. Numeric identifiers with leading zeroes are
rejected to remain SemVer-compatible. The selected tag must resolve to a commit
reachable from `master`. Tags should be immutable. A channel never falls back
to `master` or to the other channel when no matching tag exists.

Updates are manual:

```bash
ippontipp-deploy check
ippontipp-deploy update
```

The update builds a locked, relocatable Python environment from Debian's system
Python and a Vue bundle in a new release directory. Before activation, the
Python runtime is executed as the `ippontipp` service user; an unusable cached
release is discarded and rebuilt. The updater then applies migrations, switches
the `current` symlink, and restarts the web and Celery services. Activation
succeeds only after all three application services remain active and
both `/api/health/` and an Nginx-served static probe pass three consecutive
checks. Release and static-file permissions give the `www-data` group read-only
access while keeping write access with `ippontipp`. A failed service start or
runtime check switches the code symlink back, but intentionally does not reverse
database migrations.

## Public bootstrap repository

Place the contents of this directory at the root of a small public repository,
recommended as `IpponTipp-Proxmox`. The resulting public layout is:

```text
.gitignore
README.md
ct/ippontipp.sh
install/ippontipp-install.sh
bin/ippontipp-deploy
lib/release_selector.py
runtime/nginx/ippontipp.conf
runtime/systemd/ippontipp-{web,worker,beat}.service
tests/test_release_selector.py
docs/adr/0001-proxmox-test-deployment.md
```

Only this deployment adapter, its tests, and its operational documentation
belong there. Application source, GitHub credentials, generated database
credentials, and Django secrets remain private. Publish a version tag in the
bootstrap repository and use that immutable tag for installation. `main` is
useful while developing the installer but is not a stable installation source.

Example, run as `root` in the Proxmox host shell after publishing tag `v0.2.3`:

```bash
export IPPONTIPP_INSTALLER_BASE_URL="https://raw.githubusercontent.com/1OAdTZXI/IpponTipp-Proxmox/v0.2.3"
bash -c "$(curl -fsSL "$IPPONTIPP_INSTALLER_BASE_URL/ct/ippontipp.sh")"
```

This public repository is the right place for the entry script because a
private bootstrap would require credentials before it could ask for
credentials. The private application repository remains the source of the
selected tagged archive.

## First installation

The host script asks for:

- release channel;
- default or advanced LXC sizing and networking;
- private GitHub repository;
- GitHub read token;
- whether an existing reverse proxy is used and, if so, its browser-facing URL;
- optional SMTP settings.

Defaults are 2 CPU cores, 3 GiB memory, 16 GiB disk, DHCP, and an unprivileged
Debian 13 container. The LXC has Proxmox's `nesting` feature enabled because
systemd 257 needs mount-namespace support to start hardened services such as
Redis inside an unprivileged container. The script downloads the latest Debian
13 AMD64 template, creates the LXC, transfers a root-only bootstrap file, and
runs the container installer. It keeps a failed LXC for inspection.

For the private application repository, create a fine-grained personal access
token with:

- access to only the IpponTipp repository;
- repository permission `Contents: Read-only`;
- an explicit expiry suitable for the test environment.

A GitHub App is unnecessary for these two local containers. It becomes useful
only when many machines need centrally managed, short-lived credentials. The
installer stores the token as an environment variable in
`/etc/ippontipp/updater.env`, owned by root with mode `0600`; it does not pass
the token in process arguments. Rotate an expired token by editing that file.

## HTTP and an optional reverse proxy

Without a reverse proxy, open `http://<container-ip>`. Secure cookies and forced
HTTPS are disabled for this local mode.

When the prompt for an existing reverse proxy is answered with `yes`, provide
the complete URL used by the browser, for example `https://ippontipp.home.arpa`.
Configure that proxy to use `http://<container-ip>:80` as its upstream and to
forward `Host`, `X-Forwarded-For`, and `X-Forwarded-Proto`. TLS terminates at the
external proxy; the LXC still listens on plain HTTP. Do not expose this test
configuration directly to the public internet.

## Persistence and operations

Persistence is deliberately simple for this test environment. Each LXC root
disk contains:

| Path | Contents |
|---|---|
| `/var/lib/mysql` | MariaDB application data |
| `/etc/ippontipp/app.env` | Django, database, email, URL, and Celery environment |
| `/etc/ippontipp/updater.env` | Release channel and private GitHub access |
| `/opt/ippontipp/releases` | Built application releases |
| `/var/lib/ippontipp` | Installed-release metadata, Celery Beat state, and task lock |

An update preserves these paths and the database. RC and production have
independent MariaDB instances. No bind mount, external database, retention
policy, or backup automation is included; deleting the LXC deletes its data.

Useful diagnostics inside a container:

```bash
systemctl status ippontipp-web ippontipp-worker ippontipp-beat nginx mariadb redis-server
journalctl -u ippontipp-web -u ippontipp-worker -u ippontipp-beat --since today
curl --fail http://127.0.0.1/api/health/
```

## Known limitations

- The installer still requires one end-to-end acceptance run on the target
  Proxmox host; local checks cannot verify template discovery, storage,
  networking, package installation, or service startup.
- A failed service start or runtime check restores the previous code symlink,
  but database migrations are not automatically reversed.
- The root-only GitHub token requires manual expiry and rotation.
- The adapter assumes the current application layout plus Nginx, MariaDB, Redis,
  and systemd. It is not intended as a universal production topology.

## Portability beyond Proxmox

The Proxmox-specific part is limited to LXC creation and local service
provisioning. The reusable application contract is a tagged source revision,
locked Python and npm dependencies, environment-provided configuration, a
Gunicorn web process, Celery Worker and Beat processes, Redis, migrations, a
static build, and a health endpoint.

That contract maps well to a conventional IONOS VM or container host. A managed
platform such as Render would express the same web, worker, scheduler, Redis,
build, migration, and health-check responsibilities as platform services rather
than running this LXC installer. Render commonly uses PostgreSQL and platform
static-file handling, while this package currently assumes MariaDB and Nginx;
those provider adapters would need explicit changes. The application release
and process model therefore remains useful, but the Proxmox script itself is not
intended to be the universal deployment mechanism.
