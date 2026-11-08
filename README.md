# Auditoría preliminar de cámara BESDER / Xiongmai XM530

Investigación de la cámara BESDER / Xiongmai XM530 para TMIC.

## Evidencias de la memoria

| Figura | Contenido | Evidencia |
| --- | --- | --- |
| 1 | Identidad exterior y conexiones | [Abrir](figuras/figura-01.png) |
| 2 | Placa principal: ambas caras | [Abrir](figuras/figura-02.png) |
| 3 | Placa frontal e interconexiones del conjunto óptico | [Abrir](figuras/figura-03.jpg) |
| 4 | Diagrama del laboratorio | [Abrir](figuras/figura-04.png) |
| 5 | Arquitectura | [Abrir](figuras/figura-5.mmd) |
| 6 | De la recepción por contacto al montaje soldado | [Abrir](figuras/figura-06.png) |
| 7 | Versión y parámetros de memoria en U-Boot | [Abrir](figuras/figura-07.png) |
| 8 | Lectura de flash a RAM y CRC32 | [Abrir](figuras/figura-08.png) |
| 9 | Validación manual de CramFS y CRC | [Abrir](figuras/figura-09.png) |
| 10 | Árboles extraídos de cuatro particiones | [Abrir](figuras/figura-10.png) |
| 11 | Escaneo de todos los puertos TCP | [Abrir](figuras/figura-11.png) |
| 12 | Control y comienzo de los medios en DVRIP | [Abrir](figuras/figura-12.png) |
| 13 | Credenciales del proceso en la shell temprana | [Abrir](figuras/figura-13.png) |
| 14 | Montajes temporales | [Abrir](figuras/figura-14.mmd) |
| 15 | Shell root y cámara operativa al mismo tiempo | [Abrir](figuras/figura-15.png) |

Las figuras 5 y 14 se conservan como diagramas Mermaid. La galería añade fotografías, capturas de la interfaz y fotogramas del desmontaje. Los originales de las figuras compuestas están en originales/.

## Vídeo del desmontaje

https://github.com/user-attachments/assets/f265bce5-e55e-40a9-b1bc-8f64e651e0a7

[Descargar el vídeo completo (58,5 MB)](videos/desmontaje-camara.mp4).

[Capturas de tráfico originales y derivados](capturas/).

## Recorrido y reproducibilidad

- [Adquisición e inventario](docs/adquisicion.md).
- [Acceso root y scripts](docs/uart-root.md).
- [Red y comunicaciones](docs/red.md).
- [Manifiesto de archivos](MANIFEST.json) con tamaño y SHA-256.

Los PCAP originales corresponden al laboratorio con la cuenta `admin` y contraseña por defecto vacía. Sus huellas están en `datos/` y las copias saneadas se conservan como derivados.
