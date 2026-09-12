# WARP Auto for OpenWrt — Installation & Upgrade Guide

## Supported Environment
- **OpenWrt Release**: 25.12.x (Primary, apk-based) / 24.10.x (opkg-based)
- **Primary Tested Target**: `mediatek/filogic`
- **Primary Tested Architecture**: `aarch64_cortex-a53`
- **AmneziaWG Protocol**: AWG 2.0 (`kmod-amneziawg`, `amneziawg-tools`)
- **Package Managers Supported**: `apk` (native v3 packages) and `opkg` (fallback)

---

## Dependency Inventory & Sources

| Component | Source / Repository | Category | Purpose |
| :--- | :--- | :--- | :--- |
| `kmod-amneziawg` | [Slava-Shchipunov/awg-openwrt](https://slava-shchipunov.github.io/awg-openwrt/) | Required Runtime | AmneziaWG Kernel Driver (exact kernel ABI match) |
| `amneziawg-tools` | [Slava-Shchipunov/awg-openwrt](https://slava-shchipunov.github.io/awg-openwrt/) | Required Runtime | Userspace CLI (`awg`) & netifd protocol helper |
| `awg-warp-auto-quic` | Bundled / Built via OpenWrt SDK | Required Runtime | Native Mini QUIC I1 generator (`/usr/bin/quic-i1`) |
| `luci-proto-amneziawg` | Bundled WARP Auto Package | Required Runtime | Web UI, daemon coordinator & failover service |
| `ucode`, `curl`, `ca-bundle`, `resolveip`, `jsonfilter`, `luci-lib-uqr`, `libmbedtls21` | Official OpenWrt Base Feeds | Required Runtime | Scripting runtime, TLS certificates, IP & JSON helpers |

---

## Automatic Dependency Resolution & Feed Setup
`install.sh` automatically detects the running system via `/etc/openwrt_release` and `ubus call system board`:
1. Identifies distribution release version (e.g. `25.12.4`), target/subtarget (e.g. `mediatek/filogic`), and architecture (`aarch64_cortex-a53`).
2. Configures the verified AmneziaWG package feed:
   - For OpenWrt 25.x+: installs public signing key `awg-openwrt-feed.pem` into `/etc/apk/keys/` and appends repository URL `https://slava-shchipunov.github.io/awg-openwrt/<version>/<target>/<subtarget>/packages.adb` to `/etc/apk/repositories.d/customfeeds.list`.
   - Never overwrites or modifies official OpenWrt system repositories.
3. Automatically updates package indexes and installs dependencies.
4. Installs the bundled `awg-warp-auto-quic` APK and `luci-proto-amneziawg` APK.
5. Performs post-installation health checks.

---

## Installation Instructions

1. Copy the release archive to the router:
```sh
scp -O awg-warp-auto-2.0.4-r5-openwrt25.12.4-filogic.tar.gz root@192.168.10.1:/tmp/
```

2. SSH into the router and extract the archive:
```sh
ssh root@192.168.10.1
cd /tmp
tar -xzf awg-warp-auto-2.0.4-r5-openwrt25.12.4-filogic.tar.gz
cd release
```

3. Run the installer:
```sh
./install.sh
```

---

## Upgrading an Existing Installation
`upgrade.sh` safely upgrades the application and dependencies while preserving all configuration:
- Creates a timestamped pre-upgrade backup under `/root/backups/`.
- Preserves `/etc/config/awg-warp-auto` and the profile pool `/etc/awg-warp-auto/pool/`.
- Never disconnects or restarts existing network interfaces.
- If any step fails, automatically rolls back to the pre-upgrade state.

```sh
cd release
./upgrade.sh
```

---

## Manual Rollback
To revert to the state before the upgrade:
```sh
tar -xzf /root/backups/latest.tar.gz -C /
/etc/init.d/rpcd restart
/etc/init.d/awg-warp-auto restart
```

---

## Uninstallation
To completely remove WARP Auto while preserving global routing and interfaces:
```sh
cd release
./uninstall.sh
```
