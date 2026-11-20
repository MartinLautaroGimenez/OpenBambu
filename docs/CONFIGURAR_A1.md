# Configurar la Bambu Lab A1 para OpenBambu

OpenBambu habla con la impresora **directamente por la red local** con los mismos protocolos que usa Bambu Studio en modo LAN:

| Puerto | Protocolo | Uso |
|---|---|---|
| 8883 | MQTT sobre TLS | Estado y comandos |
| 6000 | TLS (JPEG) | Cámara |
| 990 | FTPS | Archivos de la SD (etapa 2) |

## 1. Activar el modo LAN y el modo desarrollador

Desde 2025 el firmware de Bambu incluye *Authorization Control*: si no activás el **Modo desarrollador**, la impresora rechaza los comandos de software de terceros (el estado se puede leer, pero no se puede controlar).

En la pantalla de la A1 (los nombres pueden variar un poco según el firmware):

1. **Ajustes → WLAN**: conectá la impresora a tu Wi-Fi y anotá la **IP**.
2. **Ajustes → Modo solo LAN** (*LAN Only Mode*): activalo y anotá el **código de acceso** (8 caracteres).
3. Con el modo LAN activo aparece **Modo desarrollador** (*Developer Mode*): activalo y aceptá el aviso.

> ⚠️ En modo LAN y modo desarrollador la impresora **se desconecta de la nube de Bambu**: Bambu Handy y la impresión remota de Bambu Studio dejan de funcionar con ella. Bambu Studio y OrcaSlicer siguen funcionando **por LAN** con la IP y el código de acceso.
> Podés volver atrás desactivando el modo LAN cuando quieras.

## 2. Número de serie

- **Ajustes → Dispositivo** (o *Información*) en la pantalla, o
- la etiqueta de la impresora, o
- Bambu Studio → Dispositivo.

Tiene la forma `03919A3B1234567` (15 caracteres).

## 3. IP fija (recomendado)

Reservá la IP de la impresora en tu router (DHCP estático) para que no cambie.

## 4. Configurar el servidor

`data/config.yaml`:

```yaml
printers:
  - id: a1
    name: Mi A1
    model: A1
    host: 192.168.1.50
    serial: 03919A3B1234567
    access_code: "12345678"
```

Reiniciá el contenedor (`docker compose restart`) y revisá los logs:

```
INFO openbambu.printer.lan: Conectado a Mi A1 (192.168.1.50)
```

## 5. Notificaciones push con ntfy (opcional, recomendado en iOS)

En **Android** la app muestra la barra de progreso y las alertas por su cuenta: el servicio "Monitoreo en segundo plano" consulta al servidor. Para recibir alertas **fuera de casa** o en **iOS**, configurá ntfy:

1. Instalá la app **ntfy** (Android/iOS) y suscribite a un topic difícil de adivinar, por ejemplo `openbambu-k3j9x2m1q`.
2. En `data/config.yaml`:
   ```yaml
   notifications:
     ntfy:
       enabled: true
       url: https://ntfy.sh   # o tu servidor ntfy propio
       topic: openbambu-k3j9x2m1q
   ```
3. Desde la app: **Ajustes → Enviar notificación de prueba**.

Las alertas importantes (impresión terminada o fallida, pausa, primera capa, errores) llegan con una **foto de la cámara** adjunta.

## 6. Acceso desde fuera de casa

No expongas el puerto 8787 a Internet. Usá una VPN:

- **Tailscale** (lo más simple): instalalo en el servidor y en el teléfono, y en la app poné la IP de Tailscale del servidor (`100.x.y.z:8787`).
- WireGuard en tu router.

## Problemas comunes

| Síntoma | Causa probable |
|---|---|
| `MQTT ... Not authorized` | Código de acceso incorrecto (cambia si se desactiva y reactiva el modo LAN) |
| El estado se ve pero los comandos no hacen nada | Falta activar el **Modo desarrollador** |
| `Connection refused` | IP incorrecta o la impresora no está en modo LAN |
| Cámara no disponible | Otra app (Bambu Studio u Orca) está viendo la cámara: la A1 admite pocas conexiones de cámara simultáneas |
| El servidor no ve la impresora desde Docker | Usá `network_mode: host` (viene así en `docker-compose.yml`) |
