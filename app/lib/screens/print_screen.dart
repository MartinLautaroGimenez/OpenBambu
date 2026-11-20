import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Configurar e iniciar (o encolar) la impresión de un archivo laminado.
class PrintScreen extends StatefulWidget {
  final String printerId;
  final LibraryItem item;
  const PrintScreen({super.key, required this.printerId, required this.item});

  @override
  State<PrintScreen> createState() => _PrintScreenState();
}

class _PrintScreenState extends State<PrintScreen> {
  late Plate _plate = widget.item.plates.first;
  List<TrayAssignment> _mapping = [];
  bool _loadingMapping = true;
  bool _busy = false;
  int _copies = 1;
  final Map<String, bool> _options = {
    'bed_leveling': true,
    'flow_cali': false,
    'timelapse': false,
    'vibration_cali': false,
  };

  @override
  void initState() {
    super.initState();
    _suggest();
  }

  Future<void> _suggest() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    setState(() => _loadingMapping = true);
    try {
      _mapping = await api.suggestMapping(widget.item.id, widget.printerId, _plate.index);
    } catch (_) {
      _mapping = [for (final f in _plate.filaments) TrayAssignment(f.id, null)];
    }
    if (mounted) setState(() => _loadingMapping = false);
  }

  bool get _complete => _mapping.isNotEmpty && _mapping.every((m) => m.tray != null) || _plate.filaments.isEmpty;

  Future<void> _submit({required bool now}) async {
    final s = context.read<AppState>();
    final api = s.api;
    final printer = s.printers[widget.printerId];
    if (api == null || printer == null) return;
    var bedClear = now;
    if (!now && !printer.status.isActive && !s.queueOf(widget.printerId).bedClear) {
      // Impresora libre: si la cama ya está vacía, el trabajo arranca enseguida
      final r = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('¿La cama está libre?'),
          content: const Text('La impresora está libre. Si la cama no tiene piezas, el trabajo arranca ya.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Todavía no')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Sí, está libre'),
            ),
          ],
        ),
      );
      if (r == null) return;
      bedClear = r;
    }
    if (now && mounted) {
      final ok = await confirm(
        context,
        title: 'Imprimir ahora',
        message: 'Confirmá que la cama está limpia y libre antes de empezar.',
        ok: 'Imprimir',
      );
      if (!ok) return;
    }
    setState(() => _busy = true);
    try {
      final q = await api.addJob(
        widget.printerId,
        libraryId: widget.item.id,
        plate: _plate.index,
        mapping: _mapping,
        options: _options,
        copies: _copies,
        startNow: now,
        bedClear: bedClear,
      );
      s.setQueue(widget.printerId, q);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            now
                ? 'Enviando a la impresora…'
                : _copies > 1
                ? '$_copies copias agregadas a la cola'
                : 'Agregado a la cola',
          ),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.danger));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = context.watch<AppState>();
    final printer = s.printers[widget.printerId];
    final api = s.api;
    final busyPrinter = printer?.status.isActive ?? true;

    return Scaffold(
      appBar: AppBar(title: Text(widget.item.name, overflow: TextOverflow.ellipsis)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 140),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Container(
              height: 220,
              color: t.colorScheme.surfaceContainer,
              child: _plate.thumbnail && api != null
                  ? Image.network(api.thumbnail(widget.item.id, _plate.index).toString(), fit: BoxFit.contain)
                  : const Icon(Icons.view_in_ar_rounded, size: 64),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Stat(
                icon: Icons.timer_outlined,
                label: 'Tiempo',
                value: _plate.predictionS == null ? '—' : formatDuration((_plate.predictionS! / 60).round()),
              ),
              Stat(
                icon: Icons.scale_rounded,
                label: 'Filamento',
                value: _plate.weightG == null ? '—' : '${_plate.weightG!.toStringAsFixed(1)} g',
              ),
              Stat(icon: Icons.palette_outlined, label: 'Colores', value: '${_plate.filaments.length}'),
            ],
          ),
          if (widget.item.plates.length > 1) ...[
            const SectionTitle('Placa'),
            Wrap(
              spacing: 8,
              children: [
                for (final p in widget.item.plates)
                  ChoiceChip(
                    label: Text('Placa ${p.index}'),
                    selected: p.index == _plate.index,
                    onSelected: (_) {
                      setState(() => _plate = p);
                      _suggest();
                    },
                  ),
              ],
            ),
          ],
          const SectionTitle('Filamentos'),
          if (_loadingMapping)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            Card(
              child: Column(
                children: [
                  for (final f in _plate.filaments)
                    _FilamentRow(
                      filament: f,
                      assignment: _mapping.firstWhere(
                        (m) => m.filamentId == f.id,
                        orElse: () {
                          final a = TrayAssignment(f.id, null);
                          _mapping.add(a);
                          return a;
                        },
                      ),
                      printer: printer,
                      onChanged: () => setState(() {}),
                      copies: _copies,
                    ),
                ],
              ),
            ),
          const SectionTitle('Opciones'),
          Card(
            child: Column(
              children: [
                _option('bed_leveling', 'Nivelación de cama', 'Recomendado. Agrega ~2 minutos'),
                _option('flow_cali', 'Calibración de flujo', 'Útil con filamentos nuevos'),
                _option('timelapse', 'Timelapse', 'Se guarda en la tarjeta SD'),
              ],
            ),
          ),
          const SectionTitle('Copias'),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Cada copia es un trabajo de la cola. Entre una y otra te pide confirmar que la cama está libre.',
                    ),
                  ),
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
                    onPressed: _copies < 50 ? () => setState(() => _copies++) : null,
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_complete && !_loadingMapping)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('Asigná una bandeja a cada filamento', style: TextStyle(color: AppColors.warning)),
                ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy || !_complete ? null : () => _submit(now: false),
                      icon: const Icon(Icons.playlist_add_rounded),
                      label: const Text('A la cola'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy || !_complete || busyPrinter || _copies > 1 ? null : () => _submit(now: true),
                      icon: _busy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.print_rounded),
                      label: const Text('Imprimir ya'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _option(String key, String title, String subtitle) => SwitchListTile(
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
    subtitle: Text(subtitle),
    value: _options[key] ?? false,
    onChanged: (v) => setState(() => _options[key] = v),
  );
}

/// Opciones de bandeja disponibles en la impresora.
class _TrayOption {
  final int id;
  final String label;
  final String? type;
  final String? color;
  _TrayOption(this.id, this.label, this.type, this.color);
}

List<_TrayOption> _trayOptions(Printer? p) {
  if (p == null) return [];
  final out = <_TrayOption>[];
  for (final u in p.status.ams) {
    for (final t in u.trays) {
      out.add(
        _TrayOption(
          t.globalId,
          'A${t.id + 1}${p.status.ams.length > 1 ? ' (AMS ${u.id + 1})' : ''}',
          t.loaded ? t.type : null,
          t.color,
        ),
      );
    }
  }
  final e = p.status.externalSpool;
  out.add(_TrayOption(254, 'Externo', e != null && e.loaded ? e.type : null, e?.color));
  return out;
}

class _FilamentRow extends StatelessWidget {
  final FileFilament filament;
  final TrayAssignment assignment;
  final Printer? printer;
  final VoidCallback onChanged;
  final int copies;
  const _FilamentRow({
    required this.filament,
    required this.assignment,
    required this.printer,
    required this.onChanged,
    this.copies = 1,
  });

  String _family(String? t) => (t ?? '').toUpperCase().split('-').first.split(' ').first;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final options = _trayOptions(printer);
    final sel = options.where((o) => o.id == assignment.tray).firstOrNull;
    final mismatch = sel != null && sel.type != null && _family(sel.type) != _family(filament.type);
    final spool = printer == null || assignment.tray == null
        ? null
        : context.watch<AppState>().spoolInTray(printer!.id, assignment.tray!);
    final need = filament.usedG == null ? null : filament.usedG! * copies;
    final flexible = _family(filament.type) == 'TPU';
    final tpuInAms = flexible && sel != null && sel.id != 254;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Dot(color: filament.color, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(filament.type, style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text(
                      [
                        'Filamento ${filament.id}',
                        if (filament.usedG != null) '${filament.usedG!.toStringAsFixed(1)} g',
                      ].join(' · '),
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_rounded, size: 18),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: sel?.id,
                hint: const Text('Elegir'),
                underline: const SizedBox.shrink(),
                borderRadius: BorderRadius.circular(14),
                items: [
                  for (final o in options)
                    DropdownMenuItem(
                      value: o.id,
                      enabled: o.type != null,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _Dot(color: o.type == null ? null : o.color, size: 18),
                          const SizedBox(width: 8),
                          Text('${o.label} · ${o.type ?? 'vacía'}'),
                        ],
                      ),
                    ),
                ],
                onChanged: (v) {
                  assignment.tray = v;
                  onChanged();
                },
              ),
            ],
          ),
          if (mismatch)
            const Padding(
              padding: EdgeInsets.only(top: 6, left: 42),
              child: Text('⚠ El tipo de filamento no coincide', style: TextStyle(color: AppColors.warning)),
            ),
          if (tpuInAms)
            const Padding(
              padding: EdgeInsets.only(top: 6, left: 42),
              child: Text(
                '⚠ El AMS lite no admite TPU: usá el carrete externo',
                style: TextStyle(color: AppColors.danger),
              ),
            ),
          if (spool != null && need != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 42),
              child: Text(
                need > spool.remainingG
                    ? '⚠ No alcanza: necesita ${need.round()} g y al carrete le quedan ${spool.remainingG.round()} g'
                    : 'Carrete ${spool.label}: quedan ${spool.remainingG.round()} g'
                          '${spool.price > 0 ? ' · costo aprox. \$ ${(need * spool.pricePerGram).round()}' : ''}',
                style: TextStyle(
                  color: need > spool.remainingG ? AppColors.danger : Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final String? color;
  final double size;
  const _Dot({required this.color, required this.size});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: parseHex(color) ?? Colors.transparent,
      shape: BoxShape.circle,
      border: Border.all(color: color == null ? Theme.of(context).colorScheme.outline : Colors.white24),
    ),
  );
}
