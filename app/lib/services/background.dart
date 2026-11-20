import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'notifications.dart';
import 'settings_store.dart';
import 'widget_service.dart';

/// Monitoreo en segundo plano (Android).
///
/// Un servicio en primer plano consulta al servidor cada pocos segundos,
/// mantiene la notificación con barra de progreso y muestra los eventos
/// (impresión terminada, errores, filamento agotado...).
class BackgroundMonitor {
  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static void init() {
    if (!supported) return;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: Notifications.progressChannel,
        channelName: 'Progreso de impresión',
        channelDescription: 'Barra de progreso de la impresión en curso',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
        showWhen: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(4000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: false,
        allowWifiLock: true,
      ),
    );
  }

  static Future<void> start() async {
    if (!supported) return;
    if (await FlutterForegroundTask.isRunningService) return;
    if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    await FlutterForegroundTask.startService(
      serviceId: Notifications.progressId,
      serviceTypes: [ForegroundServiceTypes.dataSync],
      notificationTitle: 'OpenBambu',
      notificationText: 'Monitoreando impresoras',
      notificationIcon: const NotificationIcon(metaDataName: 'ar.openbambu.service.NOTIFICATION_ICON'),
      notificationInitialRoute: '/',
      callback: backgroundCallback,
    );
  }

  static Future<void> stop() async {
    if (!supported) return;
    await FlutterForegroundTask.stopService();
  }
}

@pragma('vm:entry-point')
void backgroundCallback() {
  FlutterForegroundTask.setTaskHandler(_MonitorHandler());
}

class _MonitorHandler extends TaskHandler {
  ApiClient? _api;
  SettingsStore? _store;
  bool _busy = false;
  bool _showingProgress = false;
  int _idleTicks = 0;
  String _lastIdleText = '';
  DateTime _lastWidgetPhoto = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _store = SettingsStore(await SharedPreferences.getInstance());
    await Notifications.init();
    if (_store!.configured) _api = ApiClient(_store!.serverUrl, _store!.token);
    await _poll();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Sin impresión activa se consulta con menos frecuencia (~cada 20 s)
    if (!_showingProgress && _idleTicks++ % 5 != 0) return;
    _poll();
  }

  Future<void> _poll() async {
    final api = _api, store = _store;
    if (api == null || store == null || _busy) return;
    _busy = true;
    try {
      // Recargar preferencias por si cambiaron desde la app
      await store.prefs.reload();

      final printers = await api.printers();
      final active = printers.where((p) => p.status.isActive).toList();
      await _updateWidget(api, store, printers, active);
      if (active.isNotEmpty) {
        await Notifications.showProgress(active.first);
        _showingProgress = true;
      } else {
        final text = printers.isEmpty
            ? 'Sin impresoras configuradas'
            : printers.map((p) => '${p.name}: ${p.status.stateLabel}').join(' · ');
        if (_showingProgress || text != _lastIdleText) {
          _lastIdleText = text;
          await FlutterForegroundTask.updateService(notificationTitle: 'OpenBambu', notificationText: text);
        }
        _showingProgress = false;
      }

      final last = store.lastEventId;
      final events = await api.events(after: last);
      if (last == 0 && events.isNotEmpty) {
        // Primera ejecución: no notificar el historial viejo
        await store.setLastEventId(events.last.id);
      } else {
        for (final e in events) {
          if (e.type != 'progress') await Notifications.showEvent(e);
          await store.setLastEventId(e.id);
        }
      }
      FlutterForegroundTask.sendDataToMain({'ok': true});
    } catch (e) {
      if (_showingProgress) {
        _showingProgress = false;
        await FlutterForegroundTask.updateService(
          notificationTitle: 'OpenBambu',
          notificationText: 'Sin conexión con el servidor',
        );
      }
    } finally {
      _busy = false;
    }
  }

  /// Widget: la impresora que se está usando (o la elegida en la app), con una
  /// foto de la cámara cada ~30 s mientras imprime (cada ~5 min si no).
  Future<void> _updateWidget(ApiClient api, SettingsStore store, List<Printer> printers, List<Printer> active) async {
    if (!PrinterWidget.supported) return;
    try {
      final p = active.isNotEmpty
          ? active.first
          : printers.where((x) => x.id == store.selectedPrinter).firstOrNull ?? printers.firstOrNull;
      final every = p != null && p.status.isActive ? const Duration(seconds: 30) : const Duration(minutes: 5);
      Uint8List? photo;
      if (p != null && !p.status.isOffline && DateTime.now().difference(_lastWidgetPhoto) > every) {
        _lastWidgetPhoto = DateTime.now();
        try {
          photo = await api.snapshot(p.id);
        } catch (_) {}
      }
      await PrinterWidget.update(p, snapshot: photo);
    } catch (_) {}
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp('/');

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _api?.close();
  }
}

/// Compara listas de impresoras para decidir si hay que notificar desde la app.
bool hasActivePrint(List<Printer> printers) => printers.any((p) => p.status.isActive);
