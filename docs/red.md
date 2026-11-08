# Red y comunicaciones

Laboratorio 10.0.0.0/24: router 10.0.0.1 sin WAN y cámara 10.0.0.35. El barrido completo observó TCP 80, 554, 8899, 23000 y 34567. Las etiquetas tentativas de Nmap no identifican por sí solas cada servicio.

NETSurveillance WEB entrega la interfaz HTTP. El complemento NewActive/ActiveX utiliza DVRIP sobre TCP/34567 en las capturas observadas. Se reconocieron OPMonitor Claim, Start y Stop y se reconstruyeron medios de una sesión autenticada. Esto no prueba acceso anónimo ni MiTM.

Las imágenes de galeria/evidencias-web y la figura 12 documentan la interfaz y el tráfico. Los PCAP originales están en capturas/ y sus huellas en datos/capturas-originales-locales.json. Se incluyen sin modificar por indicación del autor, que confirma el uso de admin y contraseña por defecto vacía. Los archivos con sufijo -saneado son derivados con cambios descritos en capturas/procedencia-saneado.json. Las pruebas CVE siguen aplazadas.
