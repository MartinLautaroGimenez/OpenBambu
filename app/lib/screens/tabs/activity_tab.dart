import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'events_tab.dart';
import 'projects_view.dart';
import '../../widgets/print_detail.dart';

export '../../widgets/print_detail.dart';

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
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: 0, label: Text('Historial')),
                ButtonSegment(value: 1, label: Text('Stats')),
                ButtonSegment(value: 2, label: Text('Proyectos')),
                ButtonSegment(value: 3, label: Text('Eventos')),
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
              StatsView(printerId: widget.printer.id),
              const ProjectsView(),
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

class _PrintCard extends StatelessWidget {
  final PrintRecord rec;
  final VoidCallback onChanged;
  const _PrintCard({required this.rec, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final api = context.read<AppState>().api;
    final c = printStatusColor(rec.status);
    final minutes = rec.duration.inMinutes;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showPrintDetail(context, rec, onChanged),
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
                      style: const TextStyle(fontWeight: FontWeight.w700),
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
                        if (rec.rating != null) ...[
                          const SizedBox(width: 6),
                          Icon(
                            rec.rating == 'good' ? Icons.thumb_up_rounded : Icons.thumb_down_rounded,
                            size: 16,
                            color: rec.rating == 'good' ? AppColors.accent : AppColors.danger,
                          ),
                        ] else if (rec.needsRating) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: 'Sin calificar',
                            child: Icon(Icons.rate_review_outlined, size: 16, color: AppColors.warning),
                          ),
                        ],
                        const Spacer(),
                        if (rec.weightG != null)
                          Text(grams(rec.weightG!), style: const TextStyle(fontWeight: FontWeight.w700)),
                        if (rec.totalCost != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            money(rec.totalCost!),
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
}

// ---- estadísticas ---------------------------------------------------------------

/// Estadísticas de una impresora (o de todas si [printerId] es null).
class StatsView extends StatefulWidget {
  final String? printerId;
  final int columns;
  const StatsView({super.key, this.printerId, this.columns = 2});

  @override
  State<StatsView> createState() => _StatsViewState();
}

class _StatsViewState extends State<StatsView> {
  PrintStats? _s;
  int _version = -1;

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final s = await api.stats(printerId: widget.printerId);
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
            Text(value, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
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
            crossAxisCount: widget.columns,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: widget.columns > 2 ? 3.2 : 1.6,
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
              tile(Icons.thumb_down_rounded, 'Rechazadas', '${s.ratedBad}', AppColors.danger),
              tile(Icons.rate_review_outlined, 'Sin calificar', '${s.unrated}', AppColors.warning),
              if (s.energyKwh > 0) ...[
                tile(Icons.bolt_rounded, 'Energía', kwh(s.energyKwh), AppColors.bed),
                tile(Icons.electric_meter_outlined, 'Gasto en luz', money(s.energyCost), AppColors.info),
              ],
            ],
          ),
          const SectionTitle('Últimos 30 días'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Stat(icon: Icons.print_rounded, label: 'Impresiones', value: '${s.recentTotal}'),
                      Stat(
                        icon: Icons.verified_rounded,
                        label: 'Éxito',
                        value: s.recentSuccessRate == null ? '—' : '${s.recentSuccessRate} %',
                      ),
                      Stat(
                        icon: Icons.report_problem_outlined,
                        label: 'Problemas',
                        value: '${s.issues.fold<int>(0, (a, e) => a + e.$2)}',
                      ),
                    ],
                  ),
                  if (s.issues.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        'Sin fallas ni rechazos. Calificá las impresiones para un análisis más preciso.',
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                    )
                  else ...[
                    const SizedBox(height: 14),
                    for (final (reason, count) in s.issues)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(child: Text(reason)),
                            SizedBox(
                              width: 120,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(99),
                                child: LinearProgressIndicator(
                                  value: count / s.issues.first.$2,
                                  minHeight: 8,
                                  color: AppColors.danger,
                                  backgroundColor: t.colorScheme.surfaceContainerHighest,
                                ),
                              ),
                            ),
                            SizedBox(width: 32, child: Text('$count', textAlign: TextAlign.end)),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
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
