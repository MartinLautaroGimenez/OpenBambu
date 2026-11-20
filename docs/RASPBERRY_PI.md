# Instalar OpenBambu en una Raspberry Pi

Funciona en Raspberry Pi 4 o 5 (2 GB de RAM alcanzan) con **Raspberry Pi OS de 64 bits**.

## 1. Preparar la Pi

- Raspberry Pi OS **64 bits** (Lite alcanza, no hace falta escritorio).
- Conectada a la **misma red** que la impresora. Por cable es más estable.
- Conviene reservarle una **IP fija** en el router, igual que a la impresora.

## 2. Abrir una terminal en la Pi

Cualquiera de estas opciones:

- Teclado y monitor conectados a la Pi.
- Desde el **celular por SSH**, con Termux o JuiceSSH en Android:
  ```
  ssh usuario@IP-de-la-pi
  ```
  SSH tiene que estar activado: `sudo raspi-config` → *Interface Options* → *SSH*.

## 3. Instalar

```bash
curl -fsSL https://raw.githubusercontent.com/MartinLautaroGimenez/OpenBambu/ccr-4386d231-oij6be/scripts/instalar-rpi.sh | bash
```

El instalador:
1. Instala Docker si no está.
2. Descarga OpenBambu en `~/openbambu`.
3. Te pide la **IP**, el **número de serie** y el **código de acceso** de la impresora ([cómo obtenerlos](CONFIGURAR_A1.md)). Si dejás la IP vacía, usa el simulador.
4. Construye e inicia el servidor. La primera vez tarda unos 5 minutos.
5. Te muestra la **dirección** y el **token** para cargar en la app.

El servidor arranca solo cada vez que se enciende la Pi.

## Probar el laminador

```bash
cd ~/openbambu
sudo docker compose exec openbambu python3 -m openbambu.slicer.selftest
```
Lamina un cubo de prueba con los perfiles de la A1. En una Pi 4 tarda alrededor de un minuto.

> La imagen con OrcaSlicer ocupa unos 1,5 GB. Si la tarjeta SD es chica, se puede construir sin
> laminador: en `docker-compose.yml`, `build: { context: ./server, args: { WITH_SLICER: "0" } }`.

## Comandos útiles

```bash
cd ~/openbambu
sudo docker compose logs -f              # ver qué pasa (Ctrl+C para salir)
sudo docker compose restart              # reiniciar después de editar la config
nano data/config.yaml                    # editar impresora / ntfy
sudo cat data/api_token                  # ver el token
```

Para **actualizar** a la última versión, volvé a correr el comando de instalación: conserva tu configuración.

## Verificar que conecta con la impresora

En los logs tiene que aparecer:

```
Conectado a Mi A1 (192.168.1.50)
```

Si dice `Not authorized`, el código de acceso es incorrecto. Si dice `Connection refused`, revisá la IP y que el modo LAN esté activo. Ver la tabla de problemas en [CONFIGURAR_A1.md](CONFIGURAR_A1.md#problemas-comunes).
