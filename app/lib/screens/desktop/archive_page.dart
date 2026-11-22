import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../tabs/activity_tab.dart';

/// Archivo de impresiones: grilla con la foto final de cada impresión,
/// filtros por estado e impresora y búsqueda por nombre.
class ArchivePage extends StatefulWidget {
  final String query;
  const ArchivePage({super.key, this.query = ''});

  @override
  State<ArchivePage> createState() => _ArchivePageState();
}

class _ArchivePageState extends State<ArchivePage> {
  final List<PrintRecord> _items = [];
  bool _loading = false;
  bool _more = true;
  int _version = -1;
  String _status = 'all';
  String? _printer;

  Future<void> _load({bool reset = true}) async {
    final api = context.read<AppState>().api;
    if (api == null || (_loading && !reset)) return;
    setState(() => _loading = true);
    try {
      final page = await api.history(printerId: _printer, offset: reset ? 0 : _items.length);
      if (!mounted) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(page);
        _more = page.length >= 30;
      });
    } catch (_) {
      // se reintenta con el próximo cambio del historial
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    if (s.historyVersion != _version) {
      _version = s.historyVersion;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final t = Theme.of(context);
    final q = widget.query.trim().toLowerCase();
    final items = _items
        .where((r) => _status == 'all' || (_status == 'unrated' ? r.needsRating : r.status == _status))
        .where((r) => q.isEmpty || r.name.toLowerCase().contains(q))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final (v, label) in const [
                ('all', 'Todas'),
                ('done', 'Terminadas'),
                ('failed', 'Fallidas'),
                ('cancelled', 'Canceladas'),
                ('unrated', 'Sin calificar'),
              ])
                ChoiceChip(label: Text(label), selected: _status == v, onSelected: (_) => setState(() => _status = v)),
              if (s.printers.length > 1) ...[
                const SizedBox(width: 12),
                DropdownButton<String?>(
                  value: _printer,
                  underline: const SizedBox.shrink(),
                  hint: const Text('Todas las impresoras'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Todas las impresoras')),
                    for (final p in s.printers.values) DropdownMenuItem(value: p.id, child: Text(p.name)),
                  ],
                  onChanged: (v) {
                    _printer = v;
                    _load();
                  },
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: _items.isEmpty && _loading
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
              ? Center(
                  child: Text(
                    _items.isEmpty
                        ? 'Todavía no hay impresiones registradas.\nCada impresión nueva aparece acá con su foto.'
                        : 'No hay impresiones que coincidan.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.colorScheme.onSurfaceVariant),
                  ),
                )
              : CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                      sliver: SliverGrid(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 280,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 14,
                          childAspectRatio: 0.82,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (_, i) => _ArchiveCard(
                            rec: items[i],
                            printerName: s.printers[items[i].printerId]?.name,
                            onChanged: _load,
                          ),
                          childCount: items.length,
                        ),
                      ),
                    ),
                    if (_more)
                      SliverToBoxAdapter(
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: OutlinedButton(
                              onPressed: _loading ? null : () => _load(reset: false),
                              child: const Text('Cargar más'),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ArchiveCard extends StatelessWidget {
  final PrintRecord rec;
  final String? printerName;
  final VoidCallback onChanged;
  const _ArchiveCard({required this.rec, required this.printerName, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final api = context.read<AppState>().api;
    final c = printStatusColor(rec.status);
    final muted = t.colorScheme.onSurfaceVariant;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: InkWell(
        onTap: () => showPrintDetail(context, rec, onChanged),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: t.colorScheme.surfaceContainer),
                  if (rec.snapshot && api != null)
                    Image.network(
                      api.historySnapshot(rec.id),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Icon(Icons.image_not_supported_outlined, color: t.colorScheme.outline),
                    )
                  else
                    Icon(Icons.photo_camera_outlined, color: t.colorScheme.outline, size: 32),
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(99)),
                      child: Text(
                        rec.status == 'printing' ? 'Imprimiendo' : rec.statusLabel,
                        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700, fontSize: 11),
                      ),
                    ),
                  ),
                  if (rec.rating != null || rec.needsRating)
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                        child: Icon(
                          rec.rating == null
                              ? Icons.rate_review_outlined
                              : rec.rating == 'good'
                              ? Icons.thumb_up_rounded
                              : Icons.thumb_down_rounded,
                          size: 15,
                          color: rec.rating == null
                              ? AppColors.warning
                              : rec.rating == 'good'
                              ? AppColors.accent
                              : AppColors.danger,
                        ),
                      ),
                    ),
                  if (rec.timelapse)
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.movie_rounded, size: 16, color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rec.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [?printerName, formatClock(rec.started.toLocal())].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.labelSmall?.copyWith(color: muted),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.timer_outlined, size: 14, color: muted),
                      const SizedBox(width: 3),
                      Text(formatDuration(rec.duration.inMinutes), style: t.textTheme.labelMedium),
                      const SizedBox(width: 10),
                      if (rec.weightG != null) ...[
                        Icon(Icons.scale_rounded, size: 14, color: muted),
                        const SizedBox(width: 3),
                        Text(grams(rec.weightG!), style: t.textTheme.labelMedium),
                      ],
                      const Spacer(),
                      for (final f in rec.filaments.where((f) => f.color != null).take(4))
                        Container(
                          width: 12,
                          height: 12,
                          margin: const EdgeInsets.only(left: 3),
                          decoration: BoxDecoration(
                            color: parseHex(f.color),
                            shape: BoxShape.circle,
                            border: Border.all(color: t.colorScheme.outlineVariant),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
