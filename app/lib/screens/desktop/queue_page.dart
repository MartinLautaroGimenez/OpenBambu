import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../theme.dart';
import '../tabs/print_tab.dart';

/// Cola de todas las impresoras con contadores arriba.
class QueuePage extends StatelessWidget {
  final VoidCallback onOpenLibrary;
  const QueuePage({super.key, required this.onOpenLibrary});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final t = Theme.of(context);
    final printers = s.printers.values.toList();
    final queues = [for (final p in printers) s.queueOf(p.id)];
    final pending = queues.fold<int>(0, (a, q) => a + q.pending.where((j) => j.isQueued).length);
    final scheduled = queues.fold<int>(0, (a, q) => a + q.pending.where((j) => j.isScheduled).length);
    final active = printers.where((p) => p.status.isActive).length;
    final waiting = queues.where((q) => q.waitingBedClear).length;

    Widget counter(IconData icon, String label, String value, Color color) => Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(value, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                    Text(label, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      children: [
        Row(
          children: [
            counter(Icons.queue_rounded, 'En cola', '$pending', AppColors.info),
            const SizedBox(width: 12),
            counter(Icons.event_rounded, 'Programados', '$scheduled', AppColors.bed),
            const SizedBox(width: 12),
            counter(Icons.print_rounded, 'Imprimiendo', '$active', AppColors.accent),
            const SizedBox(width: 12),
            counter(Icons.cleaning_services_rounded, 'Esperando cama libre', '$waiting', AppColors.warning),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, c) {
            final cols = (c.maxWidth / 460).floor().clamp(1, 3);
            final w = (c.maxWidth - (cols - 1) * 16) / cols;
            return Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                for (var i = 0; i < printers.length; i++)
                  SizedBox(
                    width: w,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Row(
                            children: [
                              Icon(Icons.print_rounded, size: 18, color: stateColor(printers[i].status.state)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  printers[i].name,
                                  style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              Text(
                                printers[i].status.stateLabel,
                                style: TextStyle(color: stateColor(printers[i].status.state)),
                              ),
                            ],
                          ),
                        ),
                        QueueSection(printer: printers[i], queue: queues[i]),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
