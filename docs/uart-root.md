# UART y acceso root

Se confirmó comunicación serie a 115200 baudios, 8N1, con TX/RX cruzados y masa común. La primera lectura fue por contacto; después se soldaron los conductores. Se accedió a U-Boot usando una candidata pública contrastada en la unidad; la credencial no se incorpora al repositorio.

La shell temprana por init=/bin/sh permitió diagnosticar el firmware. La vía principal preparó copias temporales en RAM de la autenticación y del inicio, mediante montajes bind, antes de continuar con init. Las figuras 13–15 separan diagnóstico temprano y cámara operativa.

El script Python requiere pyserial, OpenSSL y GNU Screen. Solicita las credenciales al ejecutar. La copia del repositorio sustituye la contraseña temporal fija por una solicitud interactiva: conserva la procedencia del original en procedencia.json, pero no es una copia idéntica ni se ha vuelto a probar físicamente después de esta adaptación.

```sh
python3 scripts/tmic-root06-xm530.py --puerto /dev/ttyUSB0 --ver-uart
```

La investigación de autenticación y las búsquedas offline no recuperaron una contraseña válida para el login persistente. El acceso mediante montajes es un resultado distinto.
