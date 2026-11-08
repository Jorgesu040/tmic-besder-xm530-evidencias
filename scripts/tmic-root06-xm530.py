#!/usr/bin/env python3
"""Automatiza el arranque ROOT-06 de la BESDER XM530 del laboratorio."""

import argparse
import getpass
import hashlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import time

import serial


BOOT_PROMPT = rb"^U-Boot>[ \t]*(?=\r?$)"
SHELL_PROMPT = rb"^(?:~|/)?[ \t]*#[ \t]*(?=\r?$)"
PASSWORD_PROMPT = rb"Password:[ \t]*"
LOGIN_PROMPT = rb"^\(none\) login:[ \t]*"
BOOTCMD = b"bootcmd=sf probe 0;sf read 80007fc0 40000 180000;bootm 80007fc0"
BOOTARGS = (
    "mem=64M console=ttyAMA0,115200 root=/dev/mtdblock2 rootfstype=cramfs "
    "mtdparts=xm_sfc:256K(boot),1536K(kernel),1280K(romfs),4544K(user),"
    "256K(custom),320K(mtd) init=/bin/sh"
)
SOFIA_START = "dvrHelper /lib/modules /usr/bin/app.sh 127.0.0.1 9578 1 &"
LINUX_PASSWORD = None


class BootError(Exception):
    """Se recibió una respuesta inesperada del dispositivo."""


def temporary_hash(password, salt):
    """Aplica la transformación Sofia antes de calcular MD5-crypt."""
    alphabet = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    digest = hashlib.md5(password).digest()
    transformed = bytes(alphabet[(a + b) % 62] for a, b in zip(digest[::2], digest[1::2]))
    result = subprocess.run(
        ["openssl", "passwd", "-1", "-salt", salt, "-stdin"],
        input=transformed + b"\n",
        stdout=subprocess.PIPE,
        check=True,
        timeout=5,
    )
    value = result.stdout.strip()
    pattern = rb"\$1\$" + re.escape(salt.encode("ascii")) + rb"\$[./0-9A-Za-z]{22}"
    if not re.fullmatch(pattern, value):
        raise BootError("OpenSSL no devolvió un hash MD5-crypt válido.")
    return value.decode("ascii")


class UART:
    def __init__(self, port, show_rx=False):
        self.port = port
        self.show_rx = show_rx
        self.pending = b""

    def send_line(self, line):
        # Deja tiempo al receptor cuando la línea supera el tamaño de una ráfaga.
        for offset in range(0, len(line), 64):
            self.port.write(line[offset : offset + 64])
            if offset + 64 < len(line):
                time.sleep(0.012)
        self.port.write(b"\r")

    def read_chunk(self, *, trace=True):
        chunk = self.port.read(min(4096, self.port.in_waiting or 1))
        if self.show_rx and trace and chunk:
            print(chunk.decode("utf-8", errors="replace"), end="", flush=True)
        return chunk

    def wait_quiet(self):
        # Los Ctrl+C que ya salieron por el adaptador pueden generar prompts extra.
        self.pending = b""
        deadline = time.monotonic() + 3
        last_data = time.monotonic()
        while time.monotonic() < deadline:
            if self.read_chunk():
                last_data = time.monotonic()
            elif time.monotonic() - last_data >= 0.35:
                return
        raise BootError("La salida de U-Boot no se estabilizó. Entra manualmente y usa --en-uboot.")

    def wait(self, pattern, seconds, stage, *, trace=True, interrupt=False):
        pattern = re.compile(pattern, re.MULTILINE)
        deadline = time.monotonic() + seconds
        next_break = 0
        while time.monotonic() < deadline:
            self.pending += self.read_chunk(trace=trace)
            match = pattern.search(self.pending)
            if match:
                consumed = self.pending[: match.end()]
                self.pending = self.pending[match.end() :]
                return match.group(), consumed
            now = time.monotonic()
            if interrupt and now >= next_break:
                tail = self.pending.rsplit(b"\n", 1)[-1].strip()
                if not (len(tail) >= 2 and b"Password:".startswith(tail)):
                    self.port.write(b"\x03")
                next_break = now + 0.075
            if len(self.pending) > 16384:
                self.pending = self.pending[-8192:]
        raise BootError(f"Tiempo agotado en {stage}.")

    def uboot(self, line):
        self.send_line(line.encode("ascii"))
        _, output = self.wait(BOOT_PROMPT, 5, line)
        return output.splitlines()

    def linux(self, command, stage, *, trace=True):
        self.send_line(f"{command} && printf '\\n%s\\n' TMIC_'STEP_OK'".encode("ascii"))
        self.wait(rb"^TMIC_STEP_OK\r?$", 12, stage, trace=trace)
        self.wait(SHELL_PROMPT, 12, stage, trace=trace)


def boot_camera(uart, boot_secret, linux_hash):
    if boot_secret is not None:
        print("Escuchando el UART. Apaga y enciende solo la cámara ahora.", flush=True)
        uart.wait(rb"U-Boot 2014\.04|Press Ctrl\+C to stop autoboot", 90, "inicio del arranque")
        linux_boot = rb"Booting kernel|Starting kernel|Uncompressing Linux"
        try:
            prompt, _ = uart.wait(
                BOOT_PROMPT + b"|" + PASSWORD_PROMPT + b"|" + linux_boot,
                12,
                "interrupción de U-Boot",
                interrupt=True,
            )
        except BootError as error:
            raise BootError(f"{error} Entra manualmente y usa --en-uboot --ver-uart.") from error
        if re.fullmatch(linux_boot, prompt):
            raise BootError("Linux empezó a arrancar antes de que U-Boot aceptara Ctrl+C. "
                            "Entra manualmente y usa --en-uboot --ver-uart.")
        if prompt.startswith(b"Password:"):
            uart.wait_quiet()
            print("\nEnviando la contraseña de U-Boot una vez.", flush=True)
            uart.send_line(boot_secret)
            try:
                prompt, _ = uart.wait(
                    BOOT_PROMPT + rb"|(?i:Sorry, please try again!|incorrect password)",
                    8,
                    "autenticación en U-Boot",
                    trace=False,
                )
            except BootError as error:
                raise BootError(
                    f"{error} No apareció el prompt U-Boot>. Entra manualmente y usa --en-uboot."
                ) from error
            if not prompt.startswith(b"U-Boot>"):
                raise BootError("U-Boot rechazó la contraseña. Compruébala manualmente y usa --en-uboot.")

    if BOOTCMD not in uart.uboot("printenv bootcmd"):
        raise BootError("El bootcmd no coincide con el de la BESDER XM530 del laboratorio.")
    uart.uboot("setenv xmuart nfsc 0")
    uart.uboot(f"setenv bootargs {BOOTARGS}")
    env = uart.uboot("printenv xmuart bootargs")
    if b"xmuart=0" not in env or f"bootargs={BOOTARGS}".encode("ascii") not in env:
        raise BootError("El entorno temporal no coincide. Se detiene antes de arrancar Linux.")

    print("Arrancando la shell temprana.", flush=True)
    uart.send_line(b"run bootcmd")
    uart.wait(SHELL_PROMPT, 60, "shell temprana de Linux")
    uart.linux(
        'test "$$" -eq 1 && { test -r /proc/1/status || /bin/busybox mount -t proc proc /proc; }',
        "verificación de PID 1",
    )
    uart.linux("/bin/busybox mount -t tmpfs -o mode=0700 tmpfs /root", "montaje de tmpfs")
    substitution = shlex.quote(f"s|^root:[^:]*:|root:{linux_hash}:|")
    uart.linux(
        f"(umask 077; /bin/busybox sed {substitution} /etc/passwd > /root/tmic-passwd)"
        " && test -s /root/tmic-passwd",
        "creación de la cuenta temporal",
        trace=False,
    )

    uart.linux(
        f"/bin/busybox grep -Fxq {shlex.quote(SOFIA_START)} /etc/init.d/rcS"
        " && /bin/busybox sed -e 's|^[[:space:]]*/sbin/flash_eraseall .*|    exit 1|'"
        " -e '/^dvrHelper /d' /etc/init.d/rcS > /root/tmic-rcS",
        "copia de rcS sin borrado de contingencia",
    )
    hook = [
        "if [ -f /mnt/mtd/Log/ns ] && /bin/busybox mount -o bind /root/tmic-passwd /mnt/mtd/Log/ns; then",
        "  echo TMIC_PASSWD_ACTIVO",
        "else",
        "  echo TMIC_ERROR_BIND",
        "  exit 1",
        "fi",
        SOFIA_START,
    ]
    hook_args = " ".join(shlex.quote(line) for line in hook)
    uart.linux(f"printf '%s\\n' {hook_args} >> /root/tmic-rcS", "montaje temporal de autenticación")
    uart.linux(
        "/bin/busybox sh -n /root/tmic-rcS && ! /bin/busybox grep -q flash_eraseall /root/tmic-rcS"
        " && /bin/busybox chmod 700 /root/tmic-rcS"
        " && /bin/busybox mount -o bind /root/tmic-rcS /etc/init.d/rcS",
        "validación y montaje de rcS",
    )

    print("Lanzando init y esperando el login.", flush=True)
    uart.send_line(b"exec /sbin/init")
    marker, _ = uart.wait(rb"^TMIC_(?:PASSWD_ACTIVO|ERROR_BIND)\r?$", 100, "inicio de rcS")
    if marker.startswith(b"TMIC_ERROR_BIND"):
        raise BootError("Falló el montaje de la cuenta temporal.")
    uart.wait(LOGIN_PROMPT, 90, "prompt de login")
    uart.send_line(b"root")
    prompt, _ = uart.wait(PASSWORD_PROMPT + b"|" + LOGIN_PROMPT, 6, "contraseña de Linux")
    if not prompt.startswith(b"Password:"):
        raise BootError("El login volvió a solicitar el usuario.")
    uart.send_line(LINUX_PASSWORD)
    prompt, _ = uart.wait(
        SHELL_PROMPT + b"|Login incorrect|" + LOGIN_PROMPT, 12, "autenticación en Linux", trace=False
    )
    if not prompt.rstrip().endswith(b"#"):
        raise BootError("Falló la autenticación temporal en Linux.")

    uart.linux(
        r"/bin/busybox grep -Eq '^Uid:[[:space:]]+0[[:space:]]+0[[:space:]]+0[[:space:]]+0([[:space:]]|$)' /proc/$$/status",
        "UID 0 en la shell autenticada",
    )
    has_sofia = "ps | /bin/busybox grep -Eq '(^|[[:space:]/])[S]ofia([[:space:]]|$)'"
    check_sofia = (
        f'i=0; until {has_sofia}; do '
        'if [ "$i" -ge 30 ]; then break; fi; i=$((i+1)); /bin/busybox sleep 1; done; '
        f"if {has_sofia}; then printf '\\n%s\\n' TMIC_'SOFIA_OK'; "
        "else printf '\\n%s\\n' TMIC_'SOFIA_PENDIENTE'; fi"
    )
    uart.send_line(check_sofia.encode("ascii"))
    try:
        marker, _ = uart.wait(rb"^TMIC_SOFIA_(?:OK|PENDIENTE)\r?$", 40, "proceso Sofia")
    except BootError:
        return False
    return marker.strip() == b"TMIC_SOFIA_OK"


def main():
    global LINUX_PASSWORD
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--puerto", default="/dev/ttyUSB0", help="Puerto serie del USB-UART")
    parser.add_argument("--en-uboot", action="store_true", help="U-Boot ya está autenticado")
    parser.add_argument("--ver-uart", action="store_true", help="Muestra la salida serie durante el arranque")
    args = parser.parse_args()
    if not sys.stdin.isatty():
        parser.error("Ejecuta el script desde una terminal interactiva.")
    screen = shutil.which("screen")
    if screen is None:
        parser.error("Instala GNU Screen en Kali con: sudo apt install screen")

    try:
        boot_secret = None
        if not args.en_uboot:
            boot_secret = getpass.getpass("Contraseña de U-Boot: ").encode("ascii")
            if not boot_secret or any(byte < 32 or byte > 126 for byte in boot_secret):
                raise BootError("La contraseña de U-Boot debe ser ASCII imprimible.")

        LINUX_PASSWORD = getpass.getpass("Contraseña temporal para esta sesión Linux: ").encode("ascii")
        if not LINUX_PASSWORD:
            raise BootError("La contraseña temporal no puede estar vacía.")
        linux_hash = temporary_hash(LINUX_PASSWORD, secrets.token_hex(4))
        port = serial.Serial(baudrate=115200, timeout=0.05, write_timeout=2, exclusive=True)
        port.port = args.puerto
        port.dtr = False
        port.rts = False
        with port:
            sofia_running = boot_camera(UART(port, show_rx=args.ver_uart), boot_secret, linux_hash)
            if sofia_running:
                print("UID 0 y Sofia comprobados. Verifica el vídeo desde NETSurveillance.")
            else:
                print("UID 0 comprobado. Sofia no se confirmó durante la espera. Puedes revisar con ps.")
        print("Abriendo GNU Screen. Pulsa Enter para ver el prompt.", flush=True)
        return subprocess.run(
            [screen, "-m", args.puerto, "115200,cs8,-ixon,-ixoff,-istrip"]
        ).returncode
    except KeyboardInterrupt:
        return 130
    except (BootError, OSError, UnicodeError, subprocess.SubprocessError) as error:
        print(f"ROOT-06: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
