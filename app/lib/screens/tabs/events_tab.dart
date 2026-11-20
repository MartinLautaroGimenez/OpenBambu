import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

class EventsTab extends StatelessWidget {
  final Printer printer;
  const EventsTab({super.key, required this.printer});

  @override
  Widget build(BuildContext context) {
    final events = context.watch<AppState>().events.where((e) => e.printerId == printer.id).toList();
    final hms = printer.status.hms;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        if (hms.isNotEmpty) ...[
          const SectionTitle('Alertas activas'),
          Card(
            child: Column(
              children: [
                for (final h in hms)
                  ListTile(
                    leading: Icon(
                      Icons.warning_amber_rounded,
                      color: h.severity == 'fatal' || h.severity == 'serious' ? AppColors.danger : AppColors.warning,
                    ),
                    title: Text(h.description ?? 'HMS ${h.code}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('HMS ${h.code} · ${_sev(h.severity)} · tocá para ver la guía de Bambu'),
                    trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                    onTap: () => launchUrl(Uri.parse(h.url), mode: LaunchMode.externalApplication),
                  ),
              ],
            ),
          ),
        ],
        const SectionTitle('Historial'),
        if (events.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                children: [
                  Icon(Icons.notifications_none_rounded, size: 40, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 8),
                  const Text('Todavía no hay eventos', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text(
                    'Acá vas a ver inicios, pausas, errores y finales de impresión.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < events.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 64),
                  _EventTile(event: events[i]),
                ],
              ],
            ),
          ),
      ],
    );
  }

  static String _sev(String s) =>
      const {'fatal': 'fatal', 'serious': 'grave', 'common': 'normal', 'info': 'informativa'}[s] ?? s;
}

class _EventTile extends StatelessWidget {
  final PrinterEvent event;
  const _EventTile({required this.event});

  static const _icons = {
    'print_started': Icons.play_circle_rounded,
    'print_paused': Icons.pause_circle_rounded,
    'print_resumed': Icons.play_circle_rounded,
    'print_finished': Icons.check_circle_rounded,
    'print_cancelled': Icons.stop_circle_rounded,
    'print_failed': Icons.cancel_rounded,
    'first_layer': Icons.layers_rounded,
    'progress': Icons.timelapse_rounded,
    'filament_runout': Icons.report_rounded,
    'hms': Icons.warning_rounded,
    'offline': Icons.wifi_off_rounded,
    'queue_bed_clear': Icons.cleaning_services_rounded,
    'queue_error': Icons.playlist_remove_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final c = switch (event.severity) {
      'error' => AppColors.danger,
      'warning' => AppColors.warning,
      'success' => AppColors.accent,
      _ => AppColors.info,
    };
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: c.withValues(alpha: 0.15),
        child: Icon(_icons[event.type] ?? Icons.notifications_rounded, color: c, size: 22),
      ),
      title: Text(event.title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(event.message),
      trailing: Text(formatClock(event.time), style: Theme.of(context).textTheme.labelSmall),
    );
  }
}
