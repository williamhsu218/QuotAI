// Read-only developer diagnostic. Reads a bounded region of the installed
// language-server executable, not user conversations, and prints named schema
// definitions only. It never runs or modifies the vendor executable.
import fs from 'node:fs';

const binary = '/Applications/Antigravity.app/Contents/Resources/bin/language_server';
const fd = fs.openSync(binary, 'r');
const regionStart = 43_000_000;
const bytes = Buffer.alloc(7_000_000);
const length = fs.readSync(fd, bytes, 0, bytes.length, regionStart);
fs.closeSync(fd);
const region = bytes.subarray(0, length);

function varint(data, start) {
  let value = 0n, at = start;
  for (let shift = 0n; shift < 70n; shift += 7n) {
    if (at >= data.length) throw Error('truncated');
    const byte = data[at++];
    value |= BigInt(byte & 127) << shift;
    if (!(byte & 128)) return [Number(value), at];
  }
  throw Error('varint');
}
function wire(data) {
  let at = 0;
  const fields = new Map();
  while (at < data.length) {
    let tag; [tag, at] = varint(data, at);
    if (tag < 8) throw Error('tag');
    const field = tag >>> 3, type = tag & 7;
    let value;
    if (type === 0) [value, at] = varint(data, at);
    else if (type === 2) {
      let size; [size, at] = varint(data, at);
      if (size > data.length - at) throw Error('length');
      value = data.subarray(at, at + size); at += size;
    } else if (type === 1 || type === 5) { at += type === 1 ? 8 : 4; }
    else throw Error('wire');
    fields.set(field, [...(fields.get(field) || []), value]);
  }
  return fields;
}
const text = (fields, n) => fields.get(n)?.[0]?.toString('utf8');
const names = process.argv.slice(2);
if (!names.length) names.push('CortexStepGeneratorMetadata', 'ChatModelMetadata');
for (const name of names) {
  const marker = Buffer.concat([Buffer.from([10, name.length]), Buffer.from(name)]);
  let found = 0;
  for (let at = region.indexOf(marker); at >= 0; at = region.indexOf(marker, at + 1)) {
    for (let start = Math.max(0, at - 6); start < at; start++) {
      if (region[start] !== 34 && region[start] !== 26) continue;
      try {
        const [size, payload] = varint(region, start + 1);
        if (payload !== at || size > 100_000 || payload + size > region.length) continue;
        const descriptor = wire(region.subarray(payload, payload + size));
        if (text(descriptor, 1) !== name) continue;
        const fields = (descriptor.get(2) || []).map(blob => {
          const f = wire(blob);
          return {name: text(f, 1), number: f.get(3)?.[0], type: f.get(5)?.[0], typeName: text(f, 6)};
        });
        if (!fields.every(f => f.name && Number.isInteger(f.number))) continue;
        console.log(JSON.stringify({name, offset: regionStart + payload, fields}));
        found++;
      } catch { /* A name in executable strings need not be a descriptor. */ }
    }
  }
  if (!found) console.log(JSON.stringify({name, found: false}));
}
