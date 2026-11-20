import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'settings_store.dart';

const bedClearAction = 'bed_clear';

/// Botones de las notificaciones. Corre en un isolate aparte si la app está
/// cerrada, por eso lee el servidor y el token de las preferencias.
@pragma('vm:entry-point')
Future<void> onNotificationAction(NotificationResponse r) async {
  if (r.actionId != bedClearAction || r.payload == null) return;
  final store = SettingsStore(await SharedPreferences.getInstance());
  if (!store.configured) return;
  final api = ApiClient(store.serverUrl, store.token);
  try {
    await api.bedClear(r.payload!);
  } finally {
    api.close();
  }
}

/// Notificaciones locales. Se usa tanto desde la app como desde el servicio en
/// segundo plano (que corre en otro isolate y necesita inicializarlo de nuevo).
class Notifications {
  Notifications._();

  static final plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const progressChannel = 'openbambu_progress';
  static const eventsChannel = 'openbambu_events';
  static const alertsChannel = 'openbambu_alerts';

  /// Id de la notificación persistente. Coincide con el serviceId del
  /// servicio en primer plano para que sea UNA sola notificación.
  static const progressId = 4242;

  static bool get supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  static Future<void> init() async {
    if (_ready || !supported) return;
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_printer'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: onNotificationAction,
      onDidReceiveBackgroundNotificationResponse: onNotificationAction,
    );
    final android = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        progressChannel,
        'Progreso de impresión',
        description: 'Barra de progreso de la impresión en curso',
        importance: Importance.low,
        showBadge: false,
        playSound: false,
        enableVibration: false,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        eventsChannel,
        'Eventos de impresión',
        description: 'Inicio, fin, pausas y progreso',
        importance: Importance.defaultImportance,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        alertsChannel,
        'Alertas y errores',
        description: 'Errores, filamento agotado y fallas',
        importance: Importance.max,
      ),
    );
    _ready = true;
  }

  static Future<bool> requestPermission() async {
    if (!supported) return false;
    await init();
    final android = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final ios = plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    final ok =
        await android?.requestNotificationsPermission() ??
        await ios?.requestPermissions(alert: true, badge: true, sound: true) ??
        false;
    return ok;
  }

  static String formatRemaining(int min) {
    if (min <= 0) return '—';
    final h = min ~/ 60, m = min % 60;
    return h > 0 ? '${h}h ${m.toString().padLeft(2, '0')}m' : '${m}m';
  }

  /// Muestra o actualiza la notificación persistente con barra de progreso.
  /// En Android 16+ se promociona a "Live Update" (chip en la barra de estado).
  static Future<void> showProgress(Printer p) async {
    if (!supported) return;
    await init();
    final s = p.status;
    final job = s.job;
    final title = s.isPaused
        ? '⏸ ${job.name ?? 'Impresión'} · ${job.progress}%'
        : '${job.name ?? 'Imprimiendo'} · ${job.progress}%';
    final parts = <String>[
      if (s.state == 'PREPARE') s.stageLabel,
      if (s.isPaused) s.stageLabel,
      if (job.totalLayers > 0) 'Capa ${job.layer}/${job.totalLayers}',
      if (job.remainingMin > 0) 'Quedan ${formatRemaining(job.remainingMin)}',
      '🔥 ${s.temps.nozzle.round()}° / ${s.temps.bed.round()}°',
    ];
    await plugin.show(
      id: progressId,
      title: title,
      body: parts.join(' · '),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          progressChannel,
          'Progreso de impresión',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          showWhen: false,
          showProgress: true,
          maxProgress: 100,
          progress: job.progress,
          indeterminate: s.state == 'PREPARE',
          requestPromotedOngoing: true,
          shortCriticalText: '${job.progress}%',
          category: AndroidNotificationCategory.progress,
          subText: p.name,
          playSound: false,
          enableVibration: false,
        ),
        iOS: const DarwinNotificationDetails(presentSound: false, interruptionLevel: InterruptionLevel.passive),
      ),
    );
  }

  static Future<void> cancelProgress() async {
    if (!supported) return;
    await plugin.cancel(id: progressId);
  }

  /// Notificación de un evento (fin, error, pausa...).
  static Future<void> showEvent(PrinterEvent e) async {
    if (!supported) return;
    await init();
    final alert = e.severity == 'error' || e.severity == 'warning';
    final bedClear = e.type == 'queue_bed_clear';
    await plugin.show(
      id: bedClear ? 0x0BEDC1EA : e.id % 0x7FFFFFFF,
      payload: e.printerId,
      title: '${e.printerName}: ${e.title}',
      body: e.message,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          alert ? alertsChannel : eventsChannel,
          alert ? 'Alertas y errores' : 'Eventos de impresión',
          importance: alert ? Importance.max : Importance.defaultImportance,
          priority: alert ? Priority.high : Priority.defaultPriority,
          styleInformation: BigTextStyleInformation(e.message),
          actions: bedClear
              ? const [AndroidNotificationAction(bedClearAction, 'Cama libre', cancelNotification: true)]
              : null,
          category: alert ? AndroidNotificationCategory.error : AndroidNotificationCategory.status,
        ),
        iOS: DarwinNotificationDetails(
          interruptionLevel: alert ? InterruptionLevel.timeSensitive : InterruptionLevel.active,
        ),
      ),
    );
  }
}
