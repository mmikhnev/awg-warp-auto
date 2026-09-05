# Build packages for OpenWrt 25 APK firmware

## Goal

Build installable OpenWrt **`.apk`** packages for the exact firmware target,
then install them after a router reflash. This is not Android packaging.

## What must match

Before downloading an SDK, record from the router:

```sh
ubus call system board
uname -r
apk --version
apk info | grep -E '^(luci|luci-proto-amneziawg|kmod-amneziawg)'
```

The SDK release, target/subtarget, package ABI and kernel build must match the
firmware. `kmod-amneziawg` is kernel-coupled; a module built for a different
firmware build is invalid even on the same CPU.

## Linux host prerequisites

Use a real Linux host (Ubuntu 24.04/26.04 is fine). No WSL is needed.

```sh
sudo apt update
sudo apt install -y build-essential clang flex bison gawk gcc-multilib \
  gettext git libncurses5-dev libssl-dev python3-distutils rsync unzip \
  zlib1g-dev file wget
```

Download the matching OpenWrt 25 SDK from the official OpenWrt downloads
directory for the router target. Extract it, then copy this handoff directory
to the Linux machine.

## Integrate the source

The exact feed layout depends on the selected SDK. Preferred method:

1. Put `source/luci-proto-amneziawg` in a custom feed/package directory.
2. Put `source/kmod-amneziawg` and `source/amneziawg-tools` in that same
   custom feed where their Makefiles are discoverable.
3. Copy `source/awg-warp-auto-quic` only when building/testing the optional
   helper; it is not required for the working preset path.
4. Run `./scripts/feeds update -a && ./scripts/feeds install -a` if the SDK
   uses feeds, then `make defconfig`.

Do not overwrite stock LuCI files blindly. Inspect package names and adapt the
custom feed Makefiles to the SDK package conventions before compiling.

## Compile

From SDK root, after package integration:

```sh
make package/kmod-amneziawg/compile V=s
make package/amneziawg-tools/compile V=s
make package/luci-proto-amneziawg/compile V=s
# Optional, only after the above succeeds:
make package/awg-warp-auto-quic/compile V=s
```

Expected artifacts are under `bin/packages/<arch>/<feed>/` and use `.apk` on
OpenWrt 25 APK firmware. Exact filenames are SDK-dependent.

## Install on a freshly flashed router

Copy matching `.apk` files to `/tmp/packages/`, then:

```sh
apk update
apk add --allow-untrusted /tmp/packages/*.apk
```

Install runtime dependencies if they are not package dependencies:

```sh
apk add luci curl ca-bundle ucode resolveip jsonfilter luci-lib-uqr
```

Then run the WARP Auto overlay only if the package does not already include
its files. Prefer a single package that owns both LuCI and WARP Auto files;
do not install duplicate overlays over a package without checking file
ownership.

## Acceptance test

1. Open `Services -> AmneziaWG`.
2. Select/create WARP interface on a clean router.
3. Native provider in Auto mode; Custom Pool empty.
4. Generate a Native test profile and confirm `READY`.
5. Activate it, verify handshake/RX/TX and YouTube.
6. Configure ForkOp route, switch to strict health and verify YouTube again.
7. Reboot, verify pool/recovery/failover without a global network restart.
