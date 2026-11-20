import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../print_screen.dart';
import '../timelapse_screen.dart';
import 'events_tab.dart';

String money(double v) {
  final s = v.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  return '\$ $s';
}

String grams(double g) => g >= 1000 ? '${(g / 1000).toStringAsFixed(2)} kg' : '${g.round()} g';

/// Actividad: historial de impresiones, estadísticas y eventos.
class ActivityTab extends StatefulWidget {
  final Printer printer;
  const ActivityTab({super.key, required this.printer});

  @override
  State<ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends State<ActivityTab> {
  int _view = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, icon: Icon(Icons.history_rounded), label: Text('Historial')),
                ButtonSegment(value: 1, icon: Icon(Icons.insights_rounded), label: Text('Estadísticas')),
                ButtonSegment(value: 2, icon: Icon(Icons.notifications_rounded), label: Text('Eventos')),
              ],
              selected: {_view},
              onSelectionChanged: (v) => setState(() => _view = v.first),
            ),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _view,
            children: [
              _HistoryList(printer: widget.printer),
              _StatsView(printer: widget.printer),
              EventsTab(printer: widget.printer),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- historial ----------------------------------------------------------------

class _HistoryList extends StatefulWidget {
  final Printer printer;
  const _HistoryList({required this.printer});

  @override
  State<_HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<_HistoryList> {
  List<PrintRecord>? _items;
  int _version = -1;

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final items = await api.history(printerId: widget.printer.id);
      if (mounted) setState(() => _items = items);
    } catch (_) {
      if (mounted) setState(() => _items ??= []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = context.select<AppState, int>((s) => s.historyVersion);
    if (v != _version) {
      _version = v;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Todavía no hay impresiones registradas.\nCada impresión nueva aparece acá con su foto.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _PrintCard(rec: items[i], onChanged: _load),
      ),
    );
  }
}

Color _statusColor(String s) => switch (s) {
  'done' => AppColors.accent,
  'failed' => AppColors.danger,
  'cancelled' => AppColors.warning,
  _ => AppColors.info,
};

class _PrintCard extends StatelessWidget {
  final PrintRecord rec;
  final VoidCallback onChanged;
  const _PrintCard({required this.rec, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final api = context.read<AppState>().api;
    final c = _statusColor(rec.status);
    final minutes = rec.duration.inMinutes;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openDetail(context),
        child: Row(
          children: [
            Container(
              width: 96,
              height: 96,
              color: t.colorScheme.surfaceContainer,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  rec.snapshot && api != null
                      ? Image.network(api.historySnapshot(rec.id), fit: BoxFit.cover)
                      : Icon(Icons.photo_camera_outlined, color: t.colorScheme.outline),
                  if (rec.timelapse)
                    const Positioned(
                      right: 4,
                      bottom: 4,
                      child: Icon(Icons.movie_rounded, size: 18, color: Colors.white),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rec.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${formatClock(rec.started)} · ${formatDuration(minutes)}',
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        StateChip(
                          state: switch (rec.status) {
                            'done' => 'FINISH',
                            'failed' || 'cancelled' => 'FAILED',
                            _ => 'RUNNING',
                          },
                          label: rec.status == 'printing' ? 'Imprimiendo' : rec.statusLabel,
                        ),
                        const Spacer(),
                        if (rec.weightG != null)
                          Text(grams(rec.weightG!), style: const TextStyle(fontWeight: FontWeight.w700)),
                        if (rec.cost != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            money(rec.cost!),
                            style: TextStyle(color: c, fontWeight: FontWeight.w700),
                          ),
                        ],
                        const SizedBox(width: 12),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(BuildContext context) {
    final api = context.read<AppState>().api;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (c, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            if (rec.snapshot && api != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: InteractiveViewer(child: Image.network(api.historySnapshot(rec.id), fit: BoxFit.cover)),
                ),
              ),
            if (rec.timelapse && api != null) ...[
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TimelapseScreen(url: api.historyTimelapse(rec.id), title: rec.name),
                  ),
                ),
                icon: const Icon(Icons.movie_rounded),
                label: const Text('Ver timelapse'),
              ),
            ],
            const SizedBox(height: 14),
            Text(rec.name, style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              '${rec.statusLabel} · ${formatClock(rec.started)}'
              '${rec.status != 'done' && rec.status != 'printing' ? ' · al ${rec.progress}%' : ''}'
              '${rec.error != null ? ' · error ${rec.error}' : ''}',
              style: TextStyle(color: _statusColor(rec.status), fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Stat(icon: Icons.timer_outlined, label: 'Duración', value: formatDuration(rec.duration.inMinutes)),
                Stat(
                  icon: Icons.scale_rounded,
                  label: 'Filamento',
                  value: rec.weightG == null ? '—' : grams(rec.weightG!),
                ),
                Stat(icon: Icons.payments_outlined, label: 'Costo', value: rec.cost == null ? '—' : money(rec.cost!)),
              ],
            ),
            if (rec.filaments.any((f) => f.type != null)) ...[
              const SectionTitle('Filamentos'),
              for (final f in rec.filaments.where((f) => f.type != null))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(radius: 12, backgroundColor: parseHex(f.color) ?? Colors.grey),
                  title: Text(f.type ?? ''),
                  subtitle: Text(
                    f.tray == null
                        ? 'Sin bandeja'
                        : (f.tray == 254 ? 'Carrete externo' : 'Bandeja A${f.tray! % 4 + 1}'),
                  ),
                  trailing: Text(
                    [if (f.consumedG != null) grams(f.consumedG!), if (f.cost != null) money(f.cost!)].join(' · '),
                  ),
                ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                    onPressed: () async {
                      Navigator.pop(c);
                      await api?.deleteHistory(rec.id);
                      onChanged();
                    },
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Borrar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: !rec.reprintable || api == null
                        ? null
                        : () async {
                            final item = await api.libraryItem(rec.libraryId!);
                            if (!c.mounted) return;
                            Navigator.pop(c);
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => PrintScreen(printerId: rec.printerId, item: item),
                              ),
                            );
                          },
                    icon: const Icon(Icons.replay_rounded),
                    label: const Text('Reimprimir'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---- estadísticas ---------------------------------------------------------------

class _StatsView extends StatefulWidget {
  final Printer printer;
  const _StatsView({required this.printer});

  @override
  State<_StatsView> createState() => _StatsViewState();
}

class _StatsViewState extends State<_StatsView> {
  PrintStats? _s;
  int _version = -1;

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final s = await api.stats(printerId: widget.printer.id);
      if (mounted) setState(() => _s = s);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final v = context.select<AppState, int>((s) => s.historyVersion);
    if (v != _version) {
      _version = v;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final s = _s;
    if (s == null) return const Center(child: CircularProgressIndicator());
    final t = Theme.of(context);
    const months = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
    final maxPrints = s.months.fold<int>(1, (m, e) => e.prints > m ? e.prints : m);
    final totalMat = s.materials.values.fold<double>(0, (a, b) => a + b);

    Widget tile(IconData icon, String label, String value, Color color) => Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 8),
            Text(value, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            Text(label, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.6,
            children: [
              tile(Icons.print_rounded, 'Impresiones', '${s.total}', AppColors.info),
              tile(
                Icons.verified_rounded,
                'Éxito',
                s.successRate == null ? '—' : '${s.successRate} %',
                AppColors.accent,
              ),
              tile(Icons.schedule_rounded, 'Horas de impresión', s.hours.toStringAsFixed(1), AppColors.bed),
              tile(Icons.scale_rounded, 'Filamento usado', grams(s.grams), AppColors.nozzle),
              tile(Icons.payments_rounded, 'Gasto en filamento', money(s.cost), AppColors.warning),
              tile(Icons.cancel_rounded, 'Fallidas / canceladas', '${s.failed} / ${s.cancelled}', AppColors.danger),
            ],
          ),
          const SectionTitle('Impresiones por mes'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 10),
              child: SizedBox(
                height: 150,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final m in s.months)
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text('${m.prints}', style: t.textTheme.labelSmall),
                            const SizedBox(height: 4),
                            Container(
                              height: 100 * m.prints / maxPrints + 2,
                              margin: const EdgeInsets.symmetric(horizontal: 8),
                              decoration: BoxDecoration(
                                color: AppColors.accent.withValues(alpha: m.prints == 0 ? 0.2 : 0.85),
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              months[(int.tryParse(m.month.split('-').last) ?? 1) - 1],
                              style: t.textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (s.materials.isNotEmpty) ...[
            const SectionTitle('Por material'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    for (final e in s.materials.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 60,
                              child: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w700)),
                            ),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(99),
                                child: LinearProgressIndicator(
                                  value: totalMat > 0 ? e.value / totalMat : 0,
                                  minHeight: 8,
                                  backgroundColor: t.colorScheme.surfaceContainerHighest,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(width: 64, child: Text(grams(e.value), textAlign: TextAlign.end)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
