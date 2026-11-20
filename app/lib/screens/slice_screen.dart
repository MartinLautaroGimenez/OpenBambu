import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'print_screen.dart';

/// Laminar un modelo (STL/OBJ/STEP/3MF) en el servidor con OrcaSlicer.
class SliceScreen extends StatefulWidget {
  final String printerId;
  final LibraryItem item;
  const SliceScreen({super.key, required this.printerId, required this.item});

  @override
  State<SliceScreen> createState() => _SliceScreenState();
}

class _SliceScreenState extends State<SliceScreen> {
  SlicerProfiles? _profiles;
  String? _error;
  String? _process;
  String? _filament;
  int? _tray;
  int _infill = 15;
  int _walls = 2;
  String _pattern = 'grid';
  String _supports = 'none';
  bool _brim = true;
  int _copies = 1;
  bool _advanced = false;

  SliceJob? _job;
  Timer? _poll;

  static const _patterns = {
    'grid': 'Grilla',
    'gyroid': 'Giroide',
    'cubic': 'Cúbico',
    'honeycomb': 'Panal',
    'lightning': 'Rayo',
    'line': 'Líneas',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      if (!await api.slicerAvailable()) {
        setState(
          () => _error =
              'El laminador no está instalado en el servidor. Actualizá el servidor (volvé a '
              'correr el instalador) para incluir OrcaSlicer.',
        );
        return;
      }
      final p = await api.slicerProfiles(widget.printerId);
      setState(() {
        _profiles = p;
        _process = p.defaultProcess;
        final active = p.trayFilaments.where((t) => t.profile != null).firstOrNull;
        _tray = active?.tray;
        _filament = active?.profile ?? p.defaultFilament;
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _slice() async {
    final api = context.read<AppState>().api;
    if (api == null || _process == null || _filament == null) return;
    try {
      final job = await api.slice(
        widget.item.id,
        printerId: widget.printerId,
        process: _process!,
        filaments: [_filament!],
        overrides: {
          'infill': _infill,
          'infill_pattern': _pattern,
          'walls': _walls,
          'supports': _supports,
          'brim': _brim,
        },
        copies: _copies,
      );
      setState(() => _job = job);
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.danger));
      }
    }
  }

  Future<void> _refresh() async {
    final api = context.read<AppState>().api;
    final job = _job;
    if (api == null || job == null) return;
    try {
      final j = await api.sliceJob(job.id);
      if (!mounted) return;
      setState(() => _job = j);
      if (j.finished) {
        _poll?.cancel();
        if (j.status == 'done' && j.resultId != null) {
          final item = await api.libraryItem(j.resultId!);
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => PrintScreen(printerId: widget.printerId, item: item),
            ),
          );
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Laminar ${widget.item.name}', overflow: TextOverflow.ellipsis)),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : _profiles == null
          ? const Center(child: CircularProgressIndicator())
          : _job != null
          ? _progress()
          : _form(),
      bottomNavigationBar: _profiles == null || _job != null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _process != null && _filament != null ? _slice : null,
                  icon: const Icon(Icons.layers_rounded),
                  label: Text(_copies > 1 ? 'Laminar $_copies copias' : 'Laminar'),
                ),
              ),
            ),
    );
  }

  Widget _progress() {
    final j = _job!;
    final t = Theme.of(context);
    final failed = j.status == 'failed';
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 40),
        Center(
          child: failed
              ? const Icon(Icons.error_outline_rounded, size: 64, color: AppColors.danger)
              : const SizedBox(width: 64, height: 64, child: CircularProgressIndicator(strokeWidth: 5)),
        ),
        const SizedBox(height: 24),
        Text(
          failed
              ? 'No se pudo laminar'
              : j.status == 'queued'
              ? 'Esperando turno…'
              : 'Laminando…',
          textAlign: TextAlign.center,
          style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          failed ? j.error ?? '' : '${j.elapsed.round()} s · en una Raspberry Pi puede tardar unos minutos',
          textAlign: TextAlign.center,
          style: TextStyle(color: failed ? AppColors.danger : t.colorScheme.onSurfaceVariant),
        ),
        if (j.logTail.isNotEmpty) ...[
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: t.colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(12)),
            child: Text(j.logTail.take(8).join('\n'), style: t.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
          ),
        ],
        if (failed) ...[
          const SizedBox(height: 24),
          OutlinedButton(onPressed: () => setState(() => _job = null), child: const Text('Volver a los ajustes')),
        ],
      ],
    );
  }

  Widget _form() {
    final p = _profiles!;
    final t = Theme.of(context);
    final filamentsByType = <String, List<FilamentProfile>>{};
    for (final f in p.filaments) {
      filamentsByType.putIfAbsent(f.type, () => []).add(f);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        const SectionTitle('Calidad'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final pr in p.processes)
              ChoiceChip(
                label: Text(pr.label.replaceAll('mm ', ' mm · ')),
                selected: pr.name == _process,
                onSelected: (_) => setState(() => _process = pr.name),
              ),
          ],
        ),
        const SectionTitle('Filamento'),
        if (p.trayFilaments.isNotEmpty) ...[
          Text('Cargado en la impresora', style: t.textTheme.labelMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tf in p.trayFilaments.where((x) => x.profile != null))
                ChoiceChip(
                  avatar: CircleAvatar(backgroundColor: parseHex(tf.color) ?? Colors.grey, radius: 9),
                  label: Text('${tf.tray == 254 ? 'Externo' : 'A${tf.tray % 4 + 1}'} · ${tf.type}'),
                  selected: _tray == tf.tray && _filament == tf.profile,
                  onSelected: (_) => setState(() {
                    _tray = tf.tray;
                    _filament = tf.profile;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        DropdownButtonFormField<String>(
          initialValue: _filament,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Perfil de filamento'),
          items: [
            for (final e in filamentsByType.entries)
              for (final f in e.value)
                DropdownMenuItem(
                  value: f.name,
                  child: Text('${f.type} · ${f.label}', overflow: TextOverflow.ellipsis),
                ),
          ],
          onChanged: (v) => setState(() {
            _filament = v;
            _tray = null;
          }),
        ),
        const SectionTitle('Relleno'),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              children: [
                Row(
                  children: [
                    const Text('Densidad', style: TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('$_infill %', style: const TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
                Slider(
                  value: _infill.toDouble(),
                  max: 100,
                  divisions: 20,
                  onChanged: (v) => setState(() => _infill = v.round()),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final e in _patterns.entries)
                      ChoiceChip(
                        label: Text(e.value),
                        selected: _pattern == e.key,
                        onSelected: (_) => setState(() => _pattern = e.key),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        const SectionTitle('Soportes y adherencia'),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'none', label: Text('Sin soportes')),
            ButtonSegment(value: 'tree', label: Text('Árbol')),
            ButtonSegment(value: 'normal', label: Text('Normales')),
          ],
          selected: {_supports},
          onSelectionChanged: (v) => setState(() => _supports = v.first),
        ),
        const SizedBox(height: 8),
        Card(
          child: SwitchListTile(
            title: const Text('Brim', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Borde extra para que la pieza no se despegue'),
            value: _brim,
            onChanged: (v) => setState(() => _brim = v),
          ),
        ),
        const SectionTitle('Copias'),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Expanded(child: Text('Se acomodan todas en la misma placa')),
                IconButton.filledTonal(
                  onPressed: _copies > 1 ? () => setState(() => _copies--) : null,
                  icon: const Icon(Icons.remove_rounded),
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    '$_copies',
                    textAlign: TextAlign.center,
                    style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: _copies < 30 ? () => setState(() => _copies++) : null,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 4),
          title: const Text('Avanzado'),
          initiallyExpanded: _advanced,
          onExpansionChanged: (v) => _advanced = v,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Paredes (perímetros)')),
                IconButton(
                  onPressed: _walls > 1 ? () => setState(() => _walls--) : null,
                  icon: const Icon(Icons.remove_rounded),
                ),
                Text('$_walls', style: const TextStyle(fontWeight: FontWeight.w800)),
                IconButton(
                  onPressed: _walls < 10 ? () => setState(() => _walls++) : null,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
