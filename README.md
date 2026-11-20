# OpenBambu

Software libre para controlar impresoras **Bambu Lab** (pensado para la **A1**, compatible con A1 mini y P1P/P1S) desde el teléfono, por red local y sin depender de la nube.

> Proyecto independiente, **no afiliado** a Bambu Lab.

## Qué hace (etapa 1)

| | |
|---|---|
| 📷 **Cámara en vivo** | Stream de la cámara de la A1, pantalla completa con zoom |
| 📊 **Estado** | Progreso, capa, tiempo restante, hora de fin, etapa actual (nivelando, calentando…) |
| ⏯ **Control de impresión** | Pausar, reanudar, detener, velocidad (Silencioso / Estándar / Sport / Ludicrous) |
| 🌡 **Temperaturas** | Boquilla y cama, con atajos por material |
| 🌀 **Ventilador y luz** | Ventilador de capa (y aux/cámara en P1), luz |
| 🕹 **Movimiento** | Jog X/Y/Z, home, extruir/retraer, consola G-code (bloqueados mientras imprime) |
| 🎨 **AMS / AMS lite** | Colores, tipo, % restante, bandeja activa, cargar/descargar, editar tipo y color, reintentar |
| 🔔 **Notificaciones** | Notificación persistente con **barra de progreso** (Live Update en Android 16), avisos de inicio, pausa, fin, falla, filamento agotado, primera capa y errores HMS. Push opcional vía **ntfy** con captura de la cámara |

## Arquitectura

```
 ┌───────────────┐   HTTP + WebSocket   ┌──────────────────────┐   MQTT/TLS :8883   ┌─────────────┐
 │  App Flutter  │ ◄──────────────────► │  Servidor OpenBambu  │ ◄────────────────► │  Bambu A1   │
 │ Android / iOS │   (LAN o Tailscale)  │  (Docker, Python)    │   Cámara TLS :6000 │  (modo LAN) │
 └───────────────┘                      └──────────┬───────────┘                    └─────────────┘
                                                   │ push (opcional)
                                                   ▼
                                                 ntfy
```

¿Por qué un servidor? El teléfono no puede quedar conectado a la impresora todo el tiempo (Android/iOS cierran las apps en segundo plano). El servidor mantiene la conexión 24/7, detecta eventos, guarda el historial, comparte **una sola** conexión de cámara entre varios dispositivos y es donde vivirán la **cola de impresión** y el **laminador** en las próximas etapas.

```
server/   Backend Python (FastAPI + aiomqtt): conexión MQTT, cámara, API, eventos, ntfy, simulador
app/      App Flutter (Android, iOS)
docs/     Guías de configuración
```

## Inicio rápido

1. **Preparar la A1**: activar *Modo solo LAN* y *Modo desarrollador*, anotar IP, número de serie y código de acceso → [docs/CONFIGURAR_A1.md](docs/CONFIGURAR_A1.md)
2. **Levantar el servidor** (PC, NAS o Raspberry Pi con Docker):
   ```bash
   git clone <este repo> openbambu && cd openbambu
   mkdir -p data && cp config.example.yaml data/config.yaml   # completar los datos de la A1
   docker compose up -d --build
   docker compose logs openbambu | grep -i token                # token para la app
   ```
3. **Instalar la app** (ver [app/README.md](app/README.md)), ingresar `IP-del-servidor:8787` y el token.

### Probar sin impresora

```bash
docker compose run --rm -e OB_PRINTER_MODE=simulator -e OB_API_TOKEN=demo openbambu
```
El simulador imita una A1 con AMS lite: imprime trabajos de demo, responde a todos los comandos y genera una cámara sintética.

## API del servidor

Todas las rutas (salvo `/api/health`) requieren `Authorization: Bearer <token>` o `?token=`.

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/api/printers` | Impresoras con capacidades y estado |
| GET | `/api/printers/{id}/status` | Estado normalizado |
| POST | `/api/printers/{id}/print/{pause\|resume\|stop}` | Control de impresión |
| POST | `/api/printers/{id}/speed` | `{"level": 1-4}` |
| POST | `/api/printers/{id}/temperature` | `{"target": "nozzle"\|"bed", "value": 220}` |
| POST | `/api/printers/{id}/fan` | `{"fan": "part"\|"aux"\|"chamber", "percent": 0-100}` |
| POST | `/api/printers/{id}/light` | `{"on": true}` |
| POST | `/api/printers/{id}/home` · `/move` · `/extrude` · `/gcode` | Movimiento (solo sin imprimir) |
| POST | `/api/printers/{id}/ams/load` · `/ams/unload` · `/ams/control` · `/ams/filament` | AMS |
| GET | `/api/printers/{id}/camera/stream.mjpg` · `/snapshot.jpg` | Cámara |
| GET | `/api/events?after=<id>` | Historial de eventos |
| WS | `/api/ws?token=` | Estado y eventos en tiempo real |

Documentación interactiva en `http://<servidor>:8787/docs`.

## Desarrollo

```bash
# Servidor
cd server && python -m venv .venv && . .venv/bin/activate
pip install -e ".[dev]" && pytest
OB_DATA_DIR=./data OB_PRINTER_MODE=simulator OB_API_TOKEN=demo openbambu

# App
cd app && flutter pub get && flutter test && flutter run
```

## Hoja de ruta

- [x] **Etapa 1**: servidor, conexión LAN, estado, control, cámara, AMS, eventos y notificaciones
- [ ] **Etapa 2: archivos y cola**: explorar la tarjeta SD (FTPS), subir y borrar archivos, iniciar impresiones con mapeo de AMS, cola con confirmación de "cama libre" entre trabajos
- [ ] **Etapa 3: laminado**: OrcaSlicer en modo consola dentro del contenedor, perfiles de la A1, parámetros (altura de capa, relleno, soportes, brim, copias), vista previa y tiempo y filamento estimados
- [ ] **Etapa 4: catálogo de modelos**: buscador unificado (MakerWorld, Printables, Thingiverse, Thangs), descargar, laminar e imprimir desde el teléfono
- [ ] **Etapa 5: iOS**: Live Activities con progreso en la pantalla de bloqueo y la Dynamic Island, y push con APNs
- [ ] Cámara RTSP de la serie X1

## Licencia

A definir por el autor.
