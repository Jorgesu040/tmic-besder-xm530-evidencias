// Reconstruye palabras md.l little-endian y rechaza huecos o contradicciones.
// No interpreta ni ejecuta contenido del firmware. Salidas fuera del Brain.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const BASE = 0x81000000;
const SIZE = 0x800000;
const EXPECTED_CRC = 'b1c224eb';
const argumentsList = process.argv.slice(2);
const prepareRepair = argumentsList.includes('--prepare-repair');
const [outputDirectory, ...inputFiles] = argumentsList.filter(a => a !== '--prepare-repair');
if (!outputDirectory || !inputFiles.length) {
  console.error('Uso: node verificar-dump-uboot.cjs <directorio-salida> <log> [log...]');
  process.exit(2);
}
const out = path.resolve(outputDirectory);
const brainRoot = path.resolve(__dirname, '..');
if (out.toLowerCase() === brainRoot.toLowerCase() || out.toLowerCase().startsWith(brainRoot.toLowerCase() + path.sep)) {
  throw new Error('Guardar firmware y resultados de adquisición fuera del Brain.');
}
fs.mkdirSync(out, { recursive: true });
const image = Buffer.alloc(SIZE);
const covered = new Uint8Array(SIZE / 4);
const contested = new Uint8Array(SIZE / 4);
const counts = [];
const conflicts = [];
const hex = n => '0x' + n.toString(16);
const hash = b => crypto.createHash('sha256').update(b).digest('hex');

for (const [fileIndex, file] of inputFiles.entries()) {
  if (fileIndex >= 254) throw new Error('Demasiadas entradas.');
  const bytes = fs.readFileSync(file);
  const lines = bytes.toString('latin1').split('\n');
  const localCovered = new Uint8Array(SIZE / 4);
  const localImage = Buffer.alloc(SIZE);
  const info = {
    file: path.resolve(file), bytes: bytes.length, sha256: hash(bytes),
    acceptedWords: 0, uniqueWords: 0, newWordsForUnion: 0,
    duplicateWords: 0, contradictoryWords: 0, partialRows: 0,
    embeddedRows: 0, firstAddress: null, lastAddress: null, checksums: []
  };
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    const line = lines[lineIndex].replace(/\r$/, '');
    const check = line.match(/^CRC32 for ([a-f0-9]{8}) \.\.\. ([a-f0-9]{8}) ==> ([a-f0-9]{8})$/i);
    if (check) info.checksums.push({ line: lineIndex + 1, first: hex(parseInt(check[1],16)), last: hex(parseInt(check[2],16)), crc32: check[3].toLowerCase() });
    // Acepta una cabecera válida aunque haya bytes extra delante; nunca ASCII suelto.
    const row = /([a-f0-9]{8}): ([a-f0-9]{8})(?= |\r|$)/ig.exec(line);
    if (!row) continue;
    const address = parseInt(row[1], 16);
    if (address < BASE || address >= BASE + SIZE || address % 4 !== 0) continue;
    const body = line.slice(row.index + 10);
    let accepted = 0;
    for (let column = 0; column < 4; column++) {
      const token = body.slice(column * 9, column * 9 + 8);
      const next = body[column * 9 + 8];
      if (!/^[a-f0-9]{8}$/i.test(token) || (next !== undefined && next !== ' ' && next !== '\r')) break;
      const offset = address - BASE + column * 4;
      if (offset + 4 > SIZE) break;
      const index = offset / 4;
      const value = parseInt(token, 16) >>> 0;
      accepted++; info.acceptedWords++;
      if (!localCovered[index]) {
        localCovered[index] = 1; localImage.writeUInt32LE(value, offset); info.uniqueWords++;
      }
      if (!covered[index]) {
        covered[index] = 1;
        image.writeUInt32LE(value, offset); info.newWordsForUnion++;
      } else {
        info.duplicateWords++;
        if (image.readUInt32LE(offset) !== value) {
          contested[index] = 1;
          info.contradictoryWords++;
          if (conflicts.length < 200) conflicts.push({ address: hex(BASE + offset), input: fileIndex + 1, line: lineIndex + 1 });
        }
      }
    }
    if (accepted && accepted < 4) info.partialRows++;
    if (accepted && row.index !== 0) info.embeddedRows++;
    if (accepted) {
      info.firstAddress = info.firstAddress === null ? address : Math.min(info.firstAddress, address);
      info.lastAddress = info.lastAddress === null ? address + accepted * 4 : Math.max(info.lastAddress, address + accepted * 4);
    }
  }
  info.coverageBytes = info.uniqueWords * 4;
  info.coveragePercent = Number((info.coverageBytes / SIZE * 100).toFixed(4));
  if (localCovered.subarray(0, 0x1000 / 4).every(Boolean)) {
    info.pilot4096Crc32 = crc32(localImage.subarray(0, 0x1000));
  }
  info.firstAddress = info.firstAddress === null ? null : hex(info.firstAddress);
  info.lastAddressExclusive = info.lastAddress === null ? null : hex(info.lastAddress);
  delete info.lastAddress;
  counts.push(info);
}

const gaps = [];
let gapStart = null, wordsPresent = 0;
for (let i = 0; i <= covered.length; i++) {
  if (i < covered.length && covered[i]) wordsPresent++;
  if (i < covered.length && !covered[i]) {
    if (gapStart === null) gapStart = i * 4;
  } else if (gapStart !== null) {
    const end = i * 4;
    gaps.push({ ramStart: hex(BASE + gapStart), ramEndExclusive: hex(BASE + end), flashOffset: hex(gapStart), bytes: end - gapStart, command: 'md.l ' + hex(BASE + gapStart) + ' ' + hex((end - gapStart) / 4) });
    gapStart = null;
  }
}
const contradictoryWords = counts.reduce((sum, f) => sum + f.contradictoryWords, 0);
const recheck = [];
let recheckStart = null;
for (let i = 0; i <= covered.length; i++) {
  if (i < covered.length && (!covered[i] || contested[i])) {
    if (recheckStart === null) recheckStart = i * 4;
  } else if (recheckStart !== null) {
    // Máximo 4 KiB por consulta, sin ocultar ni rellenar palabras dudosas.
    for (let off = recheckStart; off < i * 4; off += 0x1000) {
      const bytes = Math.min(0x1000, i * 4 - off);
      recheck.push({ ramStart: hex(BASE + off), bytes, command: 'md.l ' + hex(BASE + off) + ' ' + hex(bytes / 4) });
    }
    recheckStart = null;
  }
}
const complete = gaps.length === 0 && contradictoryWords === 0;
const checksum = complete ? crc32(image) : null;
const report = {
  base: hex(BASE), expectedBytes: SIZE, expectedCrc32: EXPECTED_CRC,
  expectedChecksumSource: 'crc32 de RAM aportado por el alumno y registrado en investigacion-uart.log',
  inputs: counts, recoveredBytes: wordsPresent * 4,
  missingBytes: SIZE - wordsPresent * 4,
  coveragePercent: Number((wordsPresent / covered.length * 100).toFixed(4)),
  gapCount: gaps.length, contradictoryWords, conflicts,
  recheckCommands: recheck.length,
  complete, crc32: checksum, crc32MatchesExpected: complete ? checksum === EXPECTED_CRC : null,
  sha256: complete ? hash(image) : null,
  binaryWritten: complete && checksum === EXPECTED_CRC,
  note: 'Los bytes ausentes no se rellenan ni se publican como firmware completo. La combinación solo es candidata hasta cubrir todo y contrastar CRC.',
  gaps
};
if (report.binaryWritten) fs.writeFileSync(path.join(out, 'flash-original-8MiB.bin'), image, { flag: 'wx' });
fs.writeFileSync(path.join(out, 'verificacion-dump.json'), JSON.stringify(report, null, 2));
fs.writeFileSync(path.join(out, 'huecos-uart.csv'), 'ram_inicio,ram_fin_exclusivo,offset_flash,bytes,comando\n' + gaps.map(g => [g.ramStart, g.ramEndExclusive, g.flashOffset, g.bytes, g.command].join(',')).join('\n') + '\n');
fs.writeFileSync(path.join(out, 'relectura-huecos.txt'), '# Ejecutar solo tras confirmar que RAM conserva la misma imagen y CRC32 b1c224eb.\n# Incluye huecos y palabras contradictorias; cada consulta tiene como máximo 4 KiB.\n# Un comando por vez, esperar al prompt y conservar nuevo log.\n' + recheck.map(g => g.command).join('\n') + '\n');
if (prepareRepair) {
  const repairMask = Uint8Array.from(covered, (present, i) => present && !contested[i] ? 1 : 0);
  const jobs = recheck.flatMap(g => {
    const offset = Number(g.ramStart) - BASE;
    return Array.from({length: Math.ceil(g.bytes / 1024)}, (_, i) => ({ offset: offset + i * 1024, bytes: Math.min(1024, g.bytes - i * 1024) }));
  });
  for (const name of ['candidato-incompleto.bin', 'candidato-cobertura.bin', 'plan-relectura.json']) {
    if (fs.existsSync(path.join(out, name))) throw new Error('Existe estado de reparación; conservarlo y usar otro directorio para preparar.');
  }
  fs.writeFileSync(path.join(out, 'candidato-incompleto.bin'), image, {flag:'wx'});
  fs.writeFileSync(path.join(out, 'candidato-cobertura.bin'), repairMask, {flag:'wx'});
  fs.writeFileSync(path.join(out, 'plan-relectura.json'), JSON.stringify({base:BASE,size:SIZE,expectedCrc32:EXPECTED_CRC,jobs},null,2), {flag:'wx'});
}
console.log(JSON.stringify({ ...report, gaps: gaps.slice(0, 6), conflicts: conflicts.slice(0, 5) }));

function crc32(buffer) {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : c >>> 1;
    table[n] = c >>> 0;
  }
  let crc = 0xffffffff;
  for (const byte of buffer) crc = table[(crc ^ byte) & 255] ^ (crc >>> 8);
  return ((crc ^ 0xffffffff) >>> 0).toString(16).padStart(8, '0');
}
