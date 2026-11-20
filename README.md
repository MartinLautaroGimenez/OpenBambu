# OpenBambu

Software libre para controlar impresoras **Bambu Lab** (pensado para la **A1**, compatible con A1 mini y P1P/P1S) desde el teléfono, por red local y sin depender de la nube.

> Proyecto independiente, **no afiliado** a Bambu Lab.

## Qué hace

| | |
|---|---|
| 📷 **Cámara en vivo** | Stream de la cámara de la A1, pantalla completa con zoom |
| 📊 **Estado** | Progreso, capa, tiempo restante, hora de fin, etapa actual (nivelando, calentando…) |
| ⏯ **Control de impresión** | Pausar, reanudar, detener, velocidad (Silencioso / Estándar / Sport / Ludicrous) |
| 🌡 **Temperaturas** | Boquilla y cama, con atajos por material |
| 🌀 **Ventilador y luz** | Ventilador de capa (y aux/cámara en P1), luz |
| 🕹 **Movimiento** | Jog X/Y/Z, home, extruir/retraer, consola G-code (bloqueados mientras imprime) |
| 🎨 **AMS / AMS lite** | Colores, tipo, % restante, bandeja activa, cargar/descargar, editar tipo y color, reintentar |
| 📂 **Archivos** | Biblioteca en el servidor (subís .gcode.3mf desde el teléfono, con miniatura, tiempo, peso y colores) y explorador de la tarjeta SD |
| 🧾 **Cola de impresión** | Copias, reordenar, pausar; entre trabajo y trabajo espera que confirmes **"cama libre"** (también desde la notificación) |
| 🧩 **Laminador en el servidor** | Subís un STL/OBJ/STEP/3MF y lo laminás desde el teléfono con **OrcaSlicer** y los perfiles oficiales de la A1: calidad, filamento, relleno y patrón, soportes, brim, paredes y copias en la misma placa |
| 🎯 **Mapeo de AMS** | Asigna cada filamento del archivo a una bandeja por tipo y color; el **TPU va al carrete externo** (el AMS lite no lo admite) |
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
2. **Levantar el servidor**. En una **Raspberry Pi** alcanza con un comando, ver [docs/RASPBERRY_PI.md](docs/RASPBERRY_PI.md). En otra PC o NAS con Docker:
   ```bash
   git clone <este repo> openbambu && cd openbambu
   mkdir -p data && cp config.example.yaml data/config.yaml   # completar los datos de la A1
   docker compose up -d --build
   docker compose logs openbambu | grep -i token                # token para la app
   ```
3. **Instalar la app**: descargá `OpenBambu.apk` desde la sección **Releases** del repo (lo compila GitHub Actions en cada cambio) e ingresá `IP-del-servidor:8787` y el token.

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
| GET/PUT | `/api/library` (PUT `?filename=`, cuerpo = archivo) | Biblioteca de archivos |
| GET | `/api/library/{id}/plates/{n}/thumbnail.png` · `/mapping?printer_id=&plate=` | Miniatura · sugerencia de bandejas |
| GET/DELETE | `/api/printers/{id}/files?path=` · POST `/files/import` | Tarjeta SD (FTPS) |
| GET/POST | `/api/printers/{id}/queue` | Cola (agregar con `library_id`, `plate`, `mapping`, `options`, `copies`, `start_now`) |
| POST | `/api/printers/{id}/queue/bed-clear` · `/pause` · `/reorder` | Confirmar cama libre, pausar, reordenar |
| GET | `/api/slicer` · `/api/slicer/profiles?printer_id=` | Estado del laminador y perfiles de calidad/filamento |
| POST | `/api/library/{id}/slice` · GET `/api/slicer/jobs/{job}` | Laminar un modelo y seguir el progreso |
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
- [x] **Etapa 2: archivos y cola**: biblioteca, tarjeta SD (FTPS), impresión con mapeo de AMS y carrete externo, cola con confirmación de "cama libre"
- [x] **Etapa 3: laminado**: OrcaSlicer 2.5 en el contenedor (amd64 y arm64), perfiles de la A1, relleno, soportes, brim, paredes, copias, tiempo y peso estimados
- [ ] **Etapa 4: catálogo de modelos**: buscador unificado (MakerWorld, Printables, Thingiverse, Thangs), descargar, laminar e imprimir desde el teléfono
- [ ] **Etapa 5: iOS**: Live Activities con progreso en la pantalla de bloqueo y la Dynamic Island, y push con APNs
- [ ] Cámara RTSP de la serie X1

## Licencia

A definir por el autor.
