# Local QUIC I1 helper

This optional target package ports the Mini QUIC generator's ClientHello/SNI,
CRYPTO frame cutting (levels 0–4), QUIC v1 initial key derivation, AES-GCM
encryption and AES header protection. It does not register devices or access the
network. Normal calls use fresh bytes from `/dev/urandom`.

```
quic-i1 --sni w3.org
quic-i1 --sni example.com --level 4 --raw
```

The default output is the AWG expression to use as the value of `I1`. `--raw`
prints the uncut packet as hexadecimal. Default level 4 matches the current
Mini QUIC aggressive SNI-only frame layout. Deterministic `--dcid XX` and
`--random HEX64` options exist for reproducible tests, not normal profile creation.

## Build

Copy this directory into an OpenWrt SDK's `package/awg-warp-auto-quic` directory.
Enable `Network -> awg-warp-auto-quic`, then run:

```
make package/awg-warp-auto-quic/compile V=s
```

The SDK must match the router architecture and release. The dependency is the
OpenWrt `libmbedtls` source package (its runtime ABI package name is release
dependent). No JavaScript runtime is needed on the router.

For a local Linux host with the mbedTLS development package:

```
cc -std=c99 -Wall -Wextra -Werror src/quic-i1.c -lmbedcrypto -o quic-i1
node tests/parity.mjs ./quic-i1 /path/to/quic.js
```

The reference file is the unmodified JavaScript from
https://warp-generation.github.io/quic.js or
https://sageptr.github.io/mini_quic_generator/quic.js. Tests report its SHA256,
assert the recorded `w3.org` level-4 vector, and compare raw packet and AWG output
for all five levels and three hostnames (30 binary comparisons). Reference-only
validation is available with `--reference-only` in place of the binary path;
that mode does not prove the C helper has been compiled or tested.

The reference algorithm produces a synthetic QUIC cover packet, not a complete
TLS session. Successful parity alone does not demonstrate connectivity: the
generated I1 must still pass AWG handshake and critical-resource traffic tests.
