# WARP Auto for LuCI AmneziaWG

This folder is a shareable overlay for the existing `luci-proto-amneziawg` fork.
It adds **WARP Auto** directly to **Services -> AmneziaWG**:

- configurable HTTPS source URL (default `https://warp-generation.github.io`);
- fetch, validate and test WARPv1/v2/v3 candidates in isolation;
- an on-router READY pool and manual profile activation/rollback;
- selection of any existing AmneziaWG interface, or one-click creation of a new named interface on a bare router;
- direct YouTube health checks, with optional strict Forkop/policy-route verification;
- automatic failover after the configured consecutive-failure threshold;
- Native mode uses the endpoint returned by the Cloudflare registration response;
- an optional **Custom / Fallback Endpoint Pool** for networks where that
  standard ingress is unavailable. Custom entries are not presented as
  Cloudflare endpoints and must pass the same isolated AWG handshake, RX/TX
  and YouTube check before becoming READY;
- no global DNS change, no Forkop/YT2 modification, and no stored manual-profile backup.

## Fresh-router install - one command

For a router without AmneziaWG yet, **do not install AmneziaWG or its LuCI app
by hand**. Copy this folder to `/tmp` and run as `root`:

```sh
cd /tmp/awg-warp-auto-fork
sh ./install-warp-auto.sh
```

This is the complete online installer. It detects the target OpenWrt release,
architecture and package format, then installs the matching `kmod-amneziawg`,
`amneziawg-tools`, the LuCI web UI, `luci-proto-amneziawg` and its runtime
dependencies (`curl`, `ca-bundle`, `ucode`, `resolveip`, `jsonfilter`,
`luci-lib-uqr`) before installing this WARP Auto overlay.

It runs the bundled upstream installer with `-e -n`, so it skips the optional
language prompt and its old interactive interface, firewall and `service
network restart` path. The router needs working Internet access, correct time
and available OpenWrt package feeds. A universal offline archive cannot safely
include `kmod-amneziawg`: a kernel module must exactly match the router's
OpenWrt version, target and architecture.

This release deliberately requires the modern `luci-proto-amneziawg` package.
If an older firmware resolves only to legacy `luci-app-amneziawg`, the base
installer stops before the overlay is applied rather than install a broken UI.

## Overlay-only install

Use this only when the matching AmneziaWG base stack is already installed.
It requires a working `luci-proto-amneziawg`, `amneziawg-tools`, matching
`kmod-amneziawg`, `curl`, `ucode`, `ca-bundle`, `resolveip`, `jsonfilter` and
`luci-lib-uqr`.
Copy this folder to the router, then run as `root`:

```sh
cd /tmp/awg-warp-auto-fork
sh ./install-overlay.sh
```

The script checks prerequisites, copies only the overlay files, preserves an
existing `/etc/config/awg-warp-auto`, restarts `rpcd` and WARP Auto, and does
**not** stop or restart Forkop. New installs remain disabled until enabled in LuCI.

Then open **Services -> AmneziaWG**, set **Config source URL** to your desired
compatible source/mirror, and click **Create WARP interface**. This starts
initial setup: it fetches and tests candidates, and creates the interface only
after a candidate passes. Watch the setup state in the panel. On a new router
it creates only selected missing interface and its managed peer with port `51821`,
fwmark `0x01000000` and `route_allowed_ips=0`. It never creates a firewall
zone, default route, forwarding, or Forkop rule. It refuses if either section
already exists, so a live interface cannot be overwritten.

Tick **Enable WARP Auto** before clicking if the new interface should also keep
the READY pool and perform automatic failover; otherwise the created interface
remains usable but the background service stays disabled.

Fresh installs use **direct** health verification so they work before Forkop is
configured. After routing selected traffic in Forkop, tick **Verify current
Forkop/policy route** and save. Candidates must pass the isolated YouTube test
before they can become ACTIVE.

## Native endpoint source

In **Settings -> Native provider**, choose one of:

- **Auto (Cloudflare registration endpoint)** — the default. The generated
  profile uses the host and port returned by that registration; no bundled IP
  pool is assumed to be official.
- **Custom pool only** — use only endpoints entered by the operator.
- **Auto, then custom fallback** — try the registration endpoint first, then
  the custom entries if it cannot pass the isolated test.

The custom field is intentionally a user-provided fallback, useful on networks
that block a standard WARP ingress. Failed profiles are disposable by default:
they are removed after a failed isolated test rather than accumulating in the
pool. Set `retain_failed_profiles=1` only when diagnostics require retaining
them temporarily.

## Layout

- `overlay/` - exact files installed onto an already prepared router.
- `source/` - full modified fork source, without `.git` metadata.
- `install-overlay.sh` - safe direct-overlay installer.
- `install-base.sh` - base-package installer with interface setup disabled.
- `install-warp-auto.sh` - both installation steps for a blank router.
- `SHA256SUMS` - integrity list for payload files.
- `awg-warp-auto-fork.tar.gz.sha256` - SHA-256 for the release archive.
- `source/` - complete modified fork source if you need to build matching
  packages yourself.
- `awg-warp-auto-quic/` - optional OpenWrt target package for local dynamic
  Mini-QUIC/I1 generation. It is not required for the proven compatibility
  preset and must be built by a matching OpenWrt SDK; see its README.

No private keys, generated WARP profiles, router credentials, or live pool
files are included.
