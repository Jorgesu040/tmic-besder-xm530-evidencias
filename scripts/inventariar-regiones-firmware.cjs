// Lectura de una imagen de laboratorio; no modifica el original ni la cámara.
// Cabecera legacy: https://github.com/u-boot/u-boot/blob/master/include/image.h
// CramFS: https://github.com/util-linux/util-linux/blob/master/disk-utils/fsck.cramfs.c
'use strict';
const fs = require('node:fs');
const crypto = require('node:crypto');

const input = process.argv[2];
if (!input || process.argv.length !== 3) {
  console.error('Uso: node inventariar-regiones-firmware.cjs <flash-8MiB.bin>');
  process.exit(2);
}
const data = fs.readFileSync(input);
if (data.length !== 0x800000) throw new Error('Se esperan exactamente 8 MiB.');
const crcTable = Array.from({ length: 256 }, (_, n) => {
  for (let k = 0; k < 8; k++) n = (n & 1) ? 0xedb88320 ^ (n >>> 1) : n >>> 1;
  return n >>> 0;
});
function crc32(buf) {
  let c = 0xffffffff;
  for (const byte of buf) c = (c >>> 8) ^ crcTable[(c ^ byte) & 255];
  return (c ^ 0xffffffff) >>> 0;
}
const hex = (n) => '0x' + n.toString(16).padStart(6, '0');
const digest = (b) => crypto.createHash('sha256').update(b).digest('hex');
const crcText = (b) => crc32(b).toString(16).padStart(8, '0');
const definitions = [
  ['mtd0', 'boot', 0x000000, 0x040000, 'Código de arranque U-Boot'],
  ['mtd1', 'kernel', 0x040000, 0x180000, 'uImage / zImage ARM'],
  ['mtd2', 'romfs', 0x1c0000, 0x140000, 'CramFS'],
  ['mtd3', 'user', 0x300000, 0x470000, 'SquashFS'],
  ['mtd4', 'custom', 0x770000, 0x040000, 'CramFS'],
  ['mtd5', 'mtd', 0x7b0000, 0x050000, 'JFFS2'],
];
let next = 0;
const regiones = definitions.map(([mtd, nombre, inicio, tamano, tipo]) => {
  if (inicio !== next || inicio + tamano > data.length) throw new Error('Mapa discontinuo o fuera de rango.');
  next = inicio + tamano;
  const slice = data.subarray(inicio, next);
  const r = {
    mtd, nombre, inicio: hex(inicio), fin_exclusivo: hex(next),
    tamano_hex: hex(tamano), bytes: tamano, kib: tamano / 1024, tipo,
    crc32_referencia: crcText(slice), sha256_referencia: digest(slice),
  };
  if (tipo === 'CramFS') {
    if (slice.readUInt32LE(0) !== 0x28cd3d45) throw new Error('Magic CramFS inesperada.');
    const declared = slice.readUInt32LE(4);
    if (declared > slice.length || declared < 64) throw new Error('Tamaño CramFS incoherente.');
    const scratch = Buffer.from(slice.subarray(0, declared));
    const stored = scratch.readUInt32LE(32);
    scratch.writeUInt32LE(0, 32);
    const remainder = slice.subarray(declared);
    r.sistema_archivos = {
      bytes_declarados: declared, bytes_fuera_fs: remainder.length,
      cola_solo_ff: remainder.every((v) => v === 0xff),
      bloques: slice.readUInt32LE(40), entradas_fsid: slice.readUInt32LE(44),
      crc32_interno_guardado: stored.toString(16).padStart(8, '0'),
      crc32_interno_calculado: crcText(scratch), crc32_interno_valido: stored === crc32(scratch),
    };
  }
  if (tipo === 'SquashFS') {
    if (slice.readUInt32LE(0) !== 0x73717368) throw new Error('Magic SquashFS inesperada.');
    r.sistema_archivos = {
      bytes_used: Number(slice.readBigUInt64LE(40)), inodos: slice.readUInt32LE(4),
      tamano_bloque: slice.readUInt32LE(12), id_compresion: slice.readUInt16LE(20),
      version: `${slice.readUInt16LE(28)}.${slice.readUInt16LE(30)}`,
    };
  }
  return r;
});
if (next !== data.length) throw new Error('El mapa no cubre la imagen.');
function uimage(offset) {
  const header = Buffer.from(data.subarray(offset, offset + 64));
  const stored = header.readUInt32BE(4);
  const bytes = header.readUInt32BE(12);
  const end = offset + 64 + bytes;
  const storedData = header.readUInt32BE(24);
  header.writeUInt32BE(0, 4);
  return {
    offset: hex(offset), bytes_payload: bytes, fin_exclusivo: hex(end),
    cabe_en_flash: end <= data.length,
    crc_cabecera_guardado: stored.toString(16).padStart(8, '0'),
    crc_cabecera_calculado: crcText(header), crc_cabecera_valido: crc32(header) === stored,
    crc_datos_guardado: storedData.toString(16).padStart(8, '0'),
    crc_datos_calculado: end <= data.length ? crcText(data.subarray(offset + 64, end)) : null,
    crc_datos_valido: end <= data.length ? crc32(data.subarray(offset + 64, end)) === storedData : null,
  };
}
console.log(JSON.stringify({
  fuente: input, bytes: data.length, sha256: digest(data), crc32: crcText(data),
  alcance: 'Regiones derivadas del archivo indicado. No acredita igualdad con otra copia sin comparar su SHA-256.',
  regiones, cabeceras_uimage: [uimage(0xc968), uimage(0x40000)],
}, null, 2));
