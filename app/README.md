# OpenBambu: app móvil

App Flutter (Android e iOS) para controlar la impresora a través del servidor OpenBambu.

## Instalar

### Android
La forma más simple: en GitHub, **Releases → OpenBambu APK** y descargá `OpenBambu.apk` desde el celular (hay que permitir "instalar apps desconocidas"). GitHub Actions lo recompila con cada cambio.

Para compilarlo vos:
```bash
flutter build apk --release
# instalar build/app/outputs/flutter-apk/app-release.apk en el teléfono
```

Al abrirla por primera vez:
1. Ingresá la dirección del servidor (`192.168.1.10:8787`) y el token.
2. Aceptá el permiso de **notificaciones** y la exclusión de **optimización de batería** (sin esto Android puede cortar el monitoreo).

### iOS
Necesitás una Mac con Xcode:
```bash
cd ios && pod install && cd ..
flutter run --release   # con el iPhone conectado
```
Con una cuenta gratuita de Apple la app dura 7 días firmada. En iOS no hay servicio en segundo plano: usá **ntfy** para las alertas con la app cerrada (ver `docs/CONFIGURAR_A1.md`).

## Estructura

```
lib/
  api/          Cliente HTTP/WebSocket, modelos y parser MJPEG
  state/        AppState: conexión en vivo, reconexión y eventos
  services/     Notificaciones, monitoreo en segundo plano (Android) y preferencias
  screens/      Configuración, impresora (Estado, Control, AMS, Eventos), cámara y ajustes
  widgets/      Vista de cámara y componentes comunes
```

## Notificación con barra de progreso (Android)

El servicio en primer plano consulta al servidor cada 4 s mientras se imprime (y cada ~20 s en reposo) y actualiza **una sola** notificación persistente con:

- título: trabajo y porcentaje
- texto: capa, tiempo restante y temperaturas
- barra de progreso (indeterminada mientras prepara)
- en **Android 16+** se promociona a *Live Update*: chip con el % en la barra de estado

Los eventos (fin, fallo, pausa, filamento agotado, errores HMS) llegan como notificaciones aparte por los canales *Eventos de impresión* y *Alertas y errores*, que se pueden configurar por separado en los ajustes de Android.
