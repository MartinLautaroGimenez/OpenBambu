import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'notifications.dart';
import 'settings_store.dart';

const _provider = 'ar.openbambu.openbambu.PrinterWidgetProvider';

/// Widget de pantalla de inicio (Android). Lo actualiza el servicio en segundo
/// plano; el botón de pausa corre [widgetAction] aunque la app esté cerrada.
class PrinterWidget {
  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> init() async {
    if (!supported) return;
    await HomeWidget.registerInteractivityCallback(widgetAction);
  }

  static Future<void> update(Printer? p, {Uint8List? snapshot}) async {
    if (!supported) return;
    if (p == null) {
      await _save(title: 'OpenBambu', subtitle: 'Sin impresoras', progress: -1, action: '');
    } else {
      final s = p.status;
      final job = s.job;
      final parts = <String>[
        if (s.isActive && job.totalLayers > 0) 'Capa ${job.layer}/${job.totalLayers}',
        if (s.isActive && job.remainingMin > 0) 'Quedan ${Notifications.formatRemaining(job.remainingMin)}',
        if (!s.isActive) s.stateLabel,
        if (s.isPaused) 'En pausa',
      ];
      await _save(
        title: s.isActive ? '${job.name ?? p.name} · ${job.progress}%' : p.name,
        subtitle: parts.join(' · '),
        progress: s.isActive ? job.progress : -1,
        indeterminate: s.state == 'PREPARE',
        action: s.isPaused ? 'resume' : (s.state == 'RUNNING' ? 'pause' : ''),
        printerId: p.id,
      );
    }
    if (snapshot != null) {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/widget_camera.jpg');
      await f.writeAsBytes(snapshot, flush: true);
      await HomeWidget.saveWidgetData<String>('image', f.path);
    }
    await HomeWidget.updateWidget(qualifiedAndroidName: _provider);
  }

  static Future<void> _save({
    required String title,
    required String subtitle,
    required int progress,
    required String action,
    bool indeterminate = false,
    String? printerId,
  }) async {
    await HomeWidget.saveWidgetData<String>('title', title);
    await HomeWidget.saveWidgetData<String>('subtitle', subtitle);
    await HomeWidget.saveWidgetData<int>('progress', progress);
    await HomeWidget.saveWidgetData<bool>('indeterminate', indeterminate);
    await HomeWidget.saveWidgetData<String>('action', action);
    if (printerId != null) await HomeWidget.saveWidgetData<String>('printer_id', printerId);
  }
}

/// Botón del widget: pausar o reanudar (corre en segundo plano).
@pragma('vm:entry-point')
Future<void> widgetAction(Uri? uri) async {
  final action = uri?.host;
  if (action != 'pause' && action != 'resume') return;
  final store = SettingsStore(await SharedPreferences.getInstance());
  if (!store.configured) return;
  final printerId = await HomeWidget.getWidgetData<String>('printer_id');
  if (printerId == null) return;
  final api = ApiClient(store.serverUrl, store.token);
  try {
    action == 'pause' ? await api.pause(printerId) : await api.resume(printerId);
    final printers = await api.printers();
    await PrinterWidget.update(printers.where((p) => p.id == printerId).firstOrNull);
  } catch (_) {
    // sin conexión: el próximo ciclo del servicio actualiza el widget
  } finally {
    api.close();
  }
}
