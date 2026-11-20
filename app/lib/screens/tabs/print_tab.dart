import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../print_screen.dart';
import '../slice_screen.dart';

/// Pestaña "Imprimir": cola, biblioteca del servidor y tarjeta SD.
class PrintTab extends StatefulWidget {
  final Printer printer;
  const PrintTab({super.key, required this.printer});

  @override
  State<PrintTab> createState() => _PrintTabState();
}

class _PrintTabState extends State<PrintTab> {
  int _source = 0; // 0 biblioteca, 1 SD
  List<LibraryItem>? _library;
  List<SdFile>? _sd;
  String _sdPath = '/';
  String? _error;
  bool _loading = false;
  double? _uploadProgress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = context.read<AppState>();
    final api = s.api;
    if (api == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      s.refreshQueue(widget.printer.id);
      if (_source == 0) {
        _library = await api.library();
      } else {
        _sd = await api.sdFiles(widget.printer.id, _sdPath);
      }
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _upload() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    final files = await FilePicker.pickFiles(type: FileType.any);
    if (files.isEmpty) return;
    final f = files.first;
    const allowed = ['.3mf', '.stl', '.obj', '.step', '.stp'];
    if (!allowed.any((e) => f.name.toLowerCase().endsWith(e))) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Formatos aceptados: 3MF, STL, OBJ y STEP')));
      }
      return;
    }
    setState(() => _uploadProgress = 0);
    try {
      final item = await api.uploadLibrary(
        f.name,
        await f.length() ?? 0,
        f.readAsByteStream(),
        onProgress: (p) => mounted ? setState(() => _uploadProgress = p) : null,
      );
      if (!mounted) return;
      setState(() => _library = [item, ...?_library]);
      _openPrint(item);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: AppColors.danger));
      }
    } finally {
      if (mounted) setState(() => _uploadProgress = null);
    }
  }

  void _openPrint(LibraryItem item) {
    if (!item.sliced) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SliceScreen(printerId: widget.printer.id, item: item),
        ),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PrintScreen(printerId: widget.printer.id, item: item),
      ),
    );
  }

  Future<void> _openSd(SdFile f) async {
    if (f.isDir) {
      _sdPath = f.path;
      _load();
      return;
    }
    if (!f.printable || !f.name.toLowerCase().endsWith('.3mf')) return;
    final api = context.read<AppState>().api!;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Expanded(child: Text('Leyendo archivo de la impresora…')),
          ],
        ),
      ),
    );
    try {
      final item = await api.importSdFile(widget.printer.id, f.path);
      if (!mounted) return;
      Navigator.pop(context);
      _openPrint(item);
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: AppColors.danger));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final q = s.queueOf(widget.printer.id);
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: _source == 0
          ? FloatingActionButton.extended(
              onPressed: _uploadProgress == null ? _upload : null,
              icon: _uploadProgress == null
                  ? const Icon(Icons.upload_file_rounded)
                  : SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(value: _uploadProgress, strokeWidth: 2.5),
                    ),
              label: Text(_uploadProgress == null ? 'Subir modelo' : 'Subiendo ${(_uploadProgress! * 100).round()}%'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          children: [
            _QueueSection(printer: widget.printer, queue: q),
            const SectionTitle('Archivos'),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, icon: Icon(Icons.folder_special_rounded), label: Text('Biblioteca')),
                ButtonSegment(value: 1, icon: Icon(Icons.sd_card_rounded), label: Text('Tarjeta SD')),
              ],
              selected: {_source},
              onSelectionChanged: (v) {
                setState(() => _source = v.first);
                _load();
              },
            ),
            const SizedBox(height: 12),
            if (_loading && (_source == 0 ? _library == null : _sd == null))
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              _Message(icon: Icons.error_outline_rounded, text: _error!, action: _load)
            else if (_source == 0)
              ..._libraryList()
            else
              ..._sdList(),
          ],
        ),
      ),
    );
  }

  List<Widget> _libraryList() {
    final items = _library ?? [];
    if (items.isEmpty) {
      return [
        const _Message(
          icon: Icons.inventory_2_outlined,
          text:
              'Tu biblioteca está vacía.\nSubí un modelo STL, OBJ, STEP o 3MF para laminarlo acá, '
              'o un .gcode.3mf ya laminado en Bambu Studio u OrcaSlicer.',
        ),
      ];
    }
    return [
      for (final it in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _LibraryCard(
            item: it,
            onTap: () => _openPrint(it),
            onDelete: () async {
              if (!await confirm(
                context,
                title: '¿Eliminar archivo?',
                message: it.name,
                ok: 'Eliminar',
                danger: true,
              )) {
                return;
              }
              if (!mounted) return;
              final ok = await act(context, (api, _) => api.deleteLibraryItem(it.id));
              if (ok && mounted) setState(() => _library?.remove(it));
            },
          ),
        ),
    ];
  }

  List<Widget> _sdList() {
    final items = _sd ?? [];
    final t = Theme.of(context);
    return [
      if (_sdPath != '/')
        ListTile(
          leading: const Icon(Icons.arrow_upward_rounded),
          title: Text(_sdPath, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: const Text('Subir un nivel'),
          onTap: () {
            final parts = _sdPath.split('/')..removeLast();
            _sdPath = parts.join('/').isEmpty ? '/' : parts.join('/');
            _load();
          },
        ),
      if (items.isEmpty) const _Message(icon: Icons.sd_card_outlined, text: 'Carpeta vacía'),
      if (items.isNotEmpty)
        Card(
          child: Column(
            children: [
              for (final f in items)
                ListTile(
                  leading: Icon(
                    f.isDir
                        ? Icons.folder_rounded
                        : f.printable
                        ? Icons.view_in_ar_rounded
                        : Icons.insert_drive_file_outlined,
                    color: f.printable ? AppColors.accent : t.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: f.isDir ? null : Text(_size(f.size)),
                  trailing: f.isDir
                      ? const Icon(Icons.chevron_right_rounded)
                      : PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'print') _openSd(f);
                            if (v == 'delete' &&
                                await confirm(
                                  context,
                                  title: '¿Borrar de la tarjeta SD?',
                                  message: f.name,
                                  ok: 'Borrar',
                                  danger: true,
                                ) &&
                                mounted) {
                              if (await act(context, (api, id) => api.deleteSdFile(id, f.path))) _load();
                            }
                          },
                          itemBuilder: (_) => [
                            if (f.printable && f.name.toLowerCase().endsWith('.3mf'))
                              const PopupMenuItem(value: 'print', child: Text('Imprimir')),
                            const PopupMenuItem(value: 'delete', child: Text('Borrar')),
                          ],
                        ),
                  onTap: () => _openSd(f),
                ),
            ],
          ),
        ),
    ];
  }

  static String _size(int b) {
    if (b > 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    if (b > 1024) return '${(b / 1024).round()} KB';
    return '$b B';
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback? action;
  const _Message({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Icon(icon, size: 36, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 10),
          Text(text, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: action, child: const Text('Reintentar')),
          ],
        ],
      ),
    ),
  );
}

class _LibraryCard extends StatelessWidget {
  final LibraryItem item;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _LibraryCard({required this.item, required this.onTap, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final api = context.read<AppState>().api;
    final plate = item.plates.isEmpty ? null : item.plates.first;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 92,
              height: 92,
              color: t.colorScheme.surfaceContainer,
              child: plate != null && plate.thumbnail && api != null
                  ? Image.network(
                      api.thumbnail(item.id, plate.index).toString(),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Icon(Icons.view_in_ar_rounded),
                    )
                  : item.catalogImage != null && api != null
                  ? Image.network(
                      api.catalogImage(item.catalogImage!, width: 200),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Icon(Icons.view_in_ar_rounded),
                    )
                  : const Icon(Icons.view_in_ar_rounded, size: 34),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      !item.sliced
                          ? 'Sin laminar · ${(item.format ?? '3mf').toUpperCase()} · tocá para laminar'
                          : [
                              if (item.plates.length > 1) '${item.plates.length} placas',
                              if (plate?.predictionS != null) formatDuration((plate!.predictionS! / 60).round()),
                              if (plate?.weightG != null) '${plate!.weightG!.round()} g',
                            ].join(' · '),
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    if (plate != null)
                      Row(
                        children: [
                          for (final f in plate.filaments)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Tooltip(
                                message: f.type,
                                child: Container(
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: parseHex(f.color) ?? Colors.grey,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white24),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            IconButton(onPressed: onDelete, icon: const Icon(Icons.delete_outline_rounded)),
          ],
        ),
      ),
    );
  }
}

class _QueueSection extends StatelessWidget {
  final Printer printer;
  final QueueState queue;
  const _QueueSection({required this.printer, required this.queue});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final pending = queue.pending;
    final history = queue.history.take(5).toList();
    void setQ(QueueState q) => context.read<AppState>().setQueue(printer.id, q);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          'Cola',
          trailing: pending.isEmpty
              ? null
              : TextButton.icon(
                  onPressed: () async {
                    final api = context.read<AppState>().api;
                    if (api == null) return;
                    setQ(await api.pauseQueue(printer.id, !queue.paused));
                  },
                  icon: Icon(queue.paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 18),
                  label: Text(queue.paused ? 'Reanudar cola' : 'Pausar cola'),
                ),
        ),
        if (queue.waitingBedClear)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.cleaning_services_rounded, color: AppColors.warning),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Retirá la pieza de la cama',
                        style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.warning, fontSize: 16),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'El próximo trabajo arranca cuando confirmes que la cama está libre.',
                  style: t.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.warning, foregroundColor: Colors.black),
                  onPressed: () async {
                    final api = context.read<AppState>().api;
                    if (api != null) setQ(await api.bedClear(printer.id));
                  },
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('La cama está libre'),
                ),
              ],
            ),
          ),
        if (queue.paused && pending.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'Cola pausada: no se van a iniciar trabajos nuevos.',
              style: TextStyle(color: AppColors.warning, fontWeight: FontWeight.w600),
            ),
          ),
        if (pending.isEmpty)
          Card(
            child: ListTile(
              leading: Icon(Icons.queue_rounded, color: t.colorScheme.outline),
              title: const Text('No hay trabajos en cola'),
              subtitle: const Text('Elegí un archivo de abajo para imprimir o encolar'),
            ),
          )
        else
          Card(
            child: ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: (from, to) async {
                final queued = pending.where((j) => j.isQueued).toList();
                final active = pending.length - queued.length;
                if (from < active || to < active) return;
                final ids = queued.map((j) => j.id).toList();
                final moved = ids.removeAt(from - active);
                ids.insert(to - active, moved);
                final api = context.read<AppState>().api;
                if (api != null) setQ(await api.reorderQueue(printer.id, ids));
              },
              children: [
                for (var i = 0; i < pending.length; i++)
                  _JobTile(
                    key: ValueKey(pending[i].id),
                    job: pending[i],
                    index: i,
                    onDelete: pending[i].isQueued
                        ? () async {
                            final api = context.read<AppState>().api;
                            if (api != null) setQ(await api.deleteJob(printer.id, pending[i].id));
                          }
                        : null,
                  ),
              ],
            ),
          ),
        if (history.isNotEmpty) ...[
          const SizedBox(height: 10),
          ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text('Historial (${queue.history.length})', style: t.textTheme.titleSmall),
            children: [
              for (final j in history) _JobTile(key: ValueKey('h${j.id}'), job: j, index: -1),
              TextButton(
                onPressed: () async {
                  final api = context.read<AppState>().api;
                  if (api != null) setQ(await api.clearHistory(printer.id));
                },
                child: const Text('Limpiar historial'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _JobTile extends StatelessWidget {
  final QueueJob job;
  final int index;
  final VoidCallback? onDelete;
  const _JobTile({super.key, required this.job, required this.index, this.onDelete});

  @override
  Widget build(BuildContext context) {
    final api = context.read<AppState>().api;
    final color = switch (job.status) {
      'printing' || 'done' => AppColors.accent,
      'uploading' || 'starting' => AppColors.info,
      'failed' => AppColors.danger,
      'cancelled' => AppColors.warning,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 46,
          height: 46,
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: api == null
              ? null
              : Image.network(
                  api.thumbnail(job.libraryId, job.plate).toString(),
                  errorBuilder: (_, _, _) => const Icon(Icons.view_in_ar_rounded),
                ),
        ),
      ),
      title: Text(job.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            job.status == 'uploading' && job.uploadProgress != null
                ? 'Subiendo a la impresora ${job.uploadProgress!.round()}%'
                : job.error != null
                ? '${job.statusLabel}: ${job.error}'
                : job.isScheduled
                ? 'Programado: ${formatClock(job.startAfter!)}'
                : job.statusLabel,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
          if (job.status == 'uploading')
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(value: (job.uploadProgress ?? 0) / 100),
            ),
        ],
      ),
      trailing: index < 0
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onDelete != null) IconButton(onPressed: onDelete, icon: const Icon(Icons.close_rounded)),
                if (job.isQueued)
                  ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_handle_rounded)),
              ],
            ),
    );
  }
}
