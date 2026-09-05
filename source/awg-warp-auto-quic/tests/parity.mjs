// Run: node tests/parity.mjs /path/to/quic-i1 /path/to/reference-quic.js
// Reference is the unmodified sageptr/warp-generation quic.js.
import { readFileSync, writeFileSync } from 'node:fs';
import { webcrypto, createHash } from 'node:crypto';
import { runInNewContext } from 'node:vm';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';

const [binary, referencePath] = process.argv.slice(2);
if (!referencePath) throw new Error('Usage: node tests/parity.mjs BINARY REFERENCE_JS');
const source = readFileSync(referencePath, 'utf8');
const CryptoKey = (await webcrypto.subtle.importKey('raw', new Uint8Array(32), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])).constructor;
const context = { window: { crypto: webcrypto }, CryptoKey,
    TextEncoder, Uint8Array, ArrayBuffer, DataView, console };
runInNewContext(source + '\nglobalThis.api = { quicTlsClientHelloSniOnly, quicTlsClientHelloToFrames, quicInitial, quicFixCutSettings, quicToAWG, quicToHex };', context);
const api = context.api;
const random = Uint8Array.from({ length: 32 }, (_, i) => i);
const randomHex = Buffer.from(random).toString('hex');
let checks = 0;
const vectors = [];
for (const sni of ['w3.org', 'example.com', 'a'.repeat(63) + '.example.org']) {
    for (let level = 0; level <= 4; level++) {
        const hello = api.quicTlsClientHelloSniOnly(sni, random);
        const [payload, cuts] = api.quicTlsClientHelloToFrames(hello, level);
        const packet = await api.quicInitial(new Uint8Array([0x42]), new Uint8Array(), new Uint8Array(), new Uint8Array([0]), payload, 0);
        api.quicFixCutSettings(cuts, packet.byteLength, 1, payload.byteLength);
        const raw = api.quicToHex(packet);
        vectors.push({ sni, level, dcid: '42', random: randomHex, raw, awg: api.quicToAWG(packet, cuts) });
        if (sni === 'w3.org' && level === 4) assert.equal(raw,
            'c8000000010142000028f2794fbaf3f793dd81f387bc6e4fae50972cb8ba0643fbd6878da50ec89778ea55104b9e70eb7a35');
        if (binary !== '--reference-only' && binary !== '--write-vectors') {
            const args = ['--sni', sni, '--level', String(level), '--dcid', '42', '--random', randomHex];
            assert.equal(execFileSync(binary, [...args, '--raw'], { encoding: 'utf8' }).trim(), raw, `${sni} level ${level} raw`);
            assert.equal(execFileSync(binary, args, { encoding: 'utf8' }).trim(), api.quicToAWG(packet, cuts), `${sni} level ${level} AWG`);
            checks += 2;
        }
    }
}
if (binary === '--write-vectors') writeFileSync(new URL('./vectors.json', import.meta.url), JSON.stringify(vectors, null, 2) + '\n');
console.log(JSON.stringify({ referenceSHA256: createHash('sha256').update(source).digest('hex'), binaryChecks: checks, knownVector: 'PASS' }));
