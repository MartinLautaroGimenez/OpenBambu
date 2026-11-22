import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../screens/print_screen.dart';
import '../screens/timelapse_screen.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

String money(double v) {
  final s = v.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  return '\$ $s';
}

String grams(double g) => g >= 1000 ? '${(g / 1000).toStringAsFixed(2)} kg' : '${g.round()} g';

String kwh(double v) => v >= 10 ? '${v.toStringAsFixed(1)} kWh' : '${v.toStringAsFixed(2)} kWh';

Color printStatusColor(String s) => switch (s) {
  'done' => AppColors.accent,
  'failed' => AppColors.danger,
  'cancelled' => AppColors.warning,
  _ => AppColors.info,
};

/// Detalle de una impresión del historial: foto, timelapse, calificación,
/// proyecto, filamentos, energía y reimprimir.
void showPrintDetail(BuildContext context, PrintRecord rec, VoidCallback onChanged) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (c, scroll) => _PrintDetail(rec: rec, scroll: scroll, onChanged: onChanged, parent: context),
    ),
  );
}

/// Pide el motivo del rechazo. Devuelve el id o null si se canceló.
Future<String?> askRejectReason(BuildContext context) => showModalBottomSheet<String>(
  context: context,
  builder: (c) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text('¿Qué salió mal?', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in rejectReasons.entries)
                ActionChip(label: Text(e.value), onPressed: () => Navigator.pop(c, e.key)),
            ],
          ),
        ),
      ],
    ),
  ),
);

/// Botones "¿Salió bien?" (Buena / Rechazada).
class RatingButtons extends StatelessWidget {
  final PrintRecord rec;
  final ValueChanged<PrintRecord> onRated;
  final bool dense;
  const RatingButtons({super.key, required this.rec, required this.onRated, this.dense = false});

  Future<void> _rate(BuildContext context, String? rating) async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    String? reason;
    if (rating == 'bad') {
      reason = await askRejectReason(context);
      if (reason == null) return;
    }
    try {
      onRated(await api.ratePrint(rec.id, rec.rating == rating && rating == 'good' ? null : rating, reason: reason));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: AppColors.danger));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final good = rec.rating == 'good', bad = rec.rating == 'bad';
    final size = dense ? const Size(0, 36) : const Size(0, 46);
    return Row(
      children: [
        Expanded(
          child: good
              ? FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: size),
                  onPressed: () => _rate(context, 'good'),
                  icon: const Icon(Icons.thumb_up_rounded, size: 18),
                  label: const Text('Buena'),
                )
              : OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: size),
                  onPressed: () => _rate(context, 'good'),
                  icon: const Icon(Icons.thumb_up_outlined, size: 18),
                  label: const Text('Buena'),
                ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: bad
              ? FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: size, backgroundColor: AppColors.danger),
                  onPressed: () => _rate(context, 'bad'),
                  icon: const Icon(Icons.thumb_down_rounded, size: 18),
                  label: const Text('Rechazada'),
                )
              : OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: size, foregroundColor: AppColors.danger),
                  onPressed: () => _rate(context, 'bad'),
                  icon: const Icon(Icons.thumb_down_outlined, size: 18),
                  label: const Text('Rechazada'),
                ),
        ),
      ],
    );
  }
}

class _PrintDetail extends StatefulWidget {
  final PrintRecord rec;
  final ScrollController scroll;
  final VoidCallback onChanged;
  final BuildContext parent;
  const _PrintDetail({required this.rec, required this.scroll, required this.onChanged, required this.parent});

  @override
  State<_PrintDetail> createState() => _PrintDetailState();
}

class _PrintDetailState extends State<_PrintDetail> {
  late PrintRecord rec = widget.rec;
  List<Project>? _projects;

  @override
  void initState() {
    super.initState();
    context
        .read<AppState>()
        .api
        ?.projects()
        .then((p) {
          if (mounted) setState(() => _projects = p);
        })
        .catchError((_) {});
  }

  void _update(PrintRecord r) {
    setState(() => rec = r);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final api = context.read<AppState>().api;
    final t = Theme.of(context);
    final parent = widget.parent;
    final projects = _projects ?? [];
    return ListView(
      controller: widget.scroll,
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
        Text(rec.name, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(
          '${rec.statusLabel} · ${formatClock(rec.started)}'
          '${rec.status != 'done' && rec.status != 'printing' ? ' · al ${rec.progress}%' : ''}'
          '${rec.error != null ? ' · error ${rec.error}' : ''}',
          style: TextStyle(color: printStatusColor(rec.status), fontWeight: FontWeight.w600),
        ),
        if (rec.status == 'done') ...[
          const SectionTitle('¿Salió bien?'),
          RatingButtons(rec: rec, onRated: _update),
          if (rec.rating == 'bad' && rec.ratingReason != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Motivo: ${rejectReasons[rec.ratingReason] ?? rec.ratingReason}',
                style: const TextStyle(color: AppColors.danger),
              ),
            ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Stat(icon: Icons.timer_outlined, label: 'Duración', value: formatDuration(rec.duration.inMinutes)),
            Stat(icon: Icons.scale_rounded, label: 'Filamento', value: rec.weightG == null ? '—' : grams(rec.weightG!)),
            Stat(
              icon: Icons.payments_outlined,
              label: 'Costo',
              value: rec.totalCost == null ? '—' : money(rec.totalCost!),
            ),
          ],
        ),
        if (rec.energyKwh != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Stat(icon: Icons.bolt_rounded, label: 'Energía', value: kwh(rec.energyKwh!)),
              Stat(
                icon: Icons.electric_meter_outlined,
                label: 'Costo de luz',
                value: rec.energyCost == null ? '—' : money(rec.energyCost!),
              ),
              Stat(
                icon: Icons.palette_outlined,
                label: 'Costo filamento',
                value: rec.cost == null ? '—' : money(rec.cost!),
              ),
            ],
          ),
        ],
        const SectionTitle('Proyecto'),
        DropdownButtonFormField<int?>(
          initialValue: projects.any((p) => p.id == rec.projectId) ? rec.projectId : null,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.workspaces_outline)),
          hint: Text(_projects == null ? 'Cargando…' : 'Sin proyecto'),
          items: [
            const DropdownMenuItem<int?>(value: null, child: Text('Sin proyecto')),
            for (final p in projects)
              DropdownMenuItem<int?>(
                value: p.id,
                child: Row(
                  children: [
                    CircleAvatar(radius: 6, backgroundColor: parseHex(p.color) ?? AppColors.accent),
                    const SizedBox(width: 10),
                    Text(p.name),
                  ],
                ),
              ),
          ],
          onChanged: api == null ? null : (v) async => _update(await api.setPrintProject(rec.id, v)),
        ),
        if (rec.filaments.any((f) => f.type != null)) ...[
          const SectionTitle('Filamentos'),
          for (final f in rec.filaments.where((f) => f.type != null))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(radius: 12, backgroundColor: parseHex(f.color) ?? Colors.grey),
              title: Text(f.type ?? ''),
              subtitle: Text(
                f.tray == null ? 'Sin bandeja' : (f.tray == 254 ? 'Carrete externo' : 'Bandeja A${f.tray! % 4 + 1}'),
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
                  final ok = await confirm(
                    context,
                    title: 'Borrar del historial',
                    message: 'Se borra la foto, el timelapse y el registro de "${rec.name}".',
                    ok: 'Borrar',
                    danger: true,
                  );
                  if (!ok || !context.mounted) return;
                  Navigator.pop(context);
                  await api?.deleteHistory(rec.id);
                  widget.onChanged();
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
                        if (!context.mounted) return;
                        Navigator.pop(context);
                        Navigator.push(
                          parent,
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
    );
  }
}
