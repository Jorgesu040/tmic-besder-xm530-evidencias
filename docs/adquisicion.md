# Adquisición e inventario

Se leyó una flash de 8 MiB a RAM desde U-Boot y se reconstruyó el texto recibido por UART. Los huecos y discrepancias se releyeron; el CRC de la reconstrucción coincidió con RAM.

- Tamaño: 8388608 bytes.
- CRC32: b1c224eb.
- SHA-256: 4f48c7c63ba24bf346bc80a9c123f729c98f2360945da2cea35c487140367290.

El SHA identifica el original local; no autentica el fabricante. El mapa de seis particiones y sus validaciones está en datos/inventario-particiones.json. Los scripts de captura y reparación necesitan una carpeta de adquisición externa al repositorio.

Comprobación de un original disponible localmente:

```sh
node scripts/inventariar-regiones-firmware.cjs /ruta/local/flash-original-8MiB.bin
```

El volcado original se conserva fuera de Git: incluye configuración persistente.
