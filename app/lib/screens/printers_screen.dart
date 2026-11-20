import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

const printerModels = {'A1': 'A1', 'A1MINI': 'A1 mini', 'P1P': 'P1P', 'P1S': 'P1S', 'X1C': 'X1 Carbon', 'X1E': 'X1E'};

/// Impresoras del servidor: listar, agregar, editar y borrar.
class PrintersScreen extends StatefulWidget {
  const PrintersScreen({super.key});

  @override
  State<PrintersScreen> createState() => _PrintersScreenState();
}

class _PrintersScreenState extends State<PrintersScreen> {
  List<AdminPrinter>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final items = await api.adminPrinters();
      if (mounted) setState(() => _items = items);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _open([AdminPrinter? p]) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => PrinterFormScreen(printer: p)),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Impresoras')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Agregar impresora'),
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : items == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  if (items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Todavía no hay impresoras en este servidor.\nTocá "Agregar impresora": las Bambu Lab de '
                        'tu red aparecen solas.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  for (final p in items)
                    Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        leading: CircleAvatar(
                          backgroundColor: (p.connected ? AppColors.accent : t.colorScheme.outline).withValues(
                            alpha: 0.18,
                          ),
                          child: Icon(
                            p.mode == 'simulator' ? Icons.science_rounded : Icons.print_rounded,
                            color: p.connected ? AppColors.accent : t.colorScheme.outline,
                          ),
                        ),
                        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: Text(
                          p.mode == 'simulator'
                              ? 'Simulador · ${printerModels[p.model] ?? p.model}'
                              : '${printerModels[p.model] ?? p.model} · ${p.host} · '
                                    '${p.connected ? 'conectada' : 'sin conexión'}',
                        ),
                        trailing: p.editable
                            ? const Icon(Icons.chevron_right_rounded)
                            : const Tooltip(
                                message: 'Definida en config.yaml',
                                child: Icon(Icons.lock_outline_rounded, size: 20),
                              ),
                        onTap: p.editable ? () => _open(p) : null,
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

/// Alta o edición de una impresora, con impresoras detectadas en la red.
class PrinterFormScreen extends StatefulWidget {
  final AdminPrinter? printer;
  const PrinterFormScreen({super.key, this.printer});

  @override
  State<PrinterFormScreen> createState() => _PrinterFormScreenState();
}

class _PrinterFormScreenState extends State<PrinterFormScreen> {
  late final _name = TextEditingController(text: widget.printer?.name ?? '');
  late final _host = TextEditingController(text: widget.printer?.host ?? '');
  late final _serial = TextEditingController(text: widget.printer?.serial ?? '');
  final _code = TextEditingController();
  late String _model = widget.printer?.model ?? 'A1';
  late bool _simulator = widget.printer?.mode == 'simulator';
  bool _showCode = false;
  bool _busy = false;
  ({bool ok, String message})? _test;
  List<DiscoveredPrinter> _found = [];
  String? _discoveryError;
  Timer? _scan;

  bool get _editing => widget.printer != null;

  @override
  void initState() {
    super.initState();
    if (!_editing) {
      _discover();
      _scan = Timer.periodic(const Duration(seconds: 4), (_) => _discover());
    }
  }

  @override
  void dispose() {
    _scan?.cancel();
    super.dispose();
  }

  Future<void> _discover() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final r = await api.discover();
      if (mounted) {
        setState(() {
          _found = r.printers;
          _discoveryError = r.error;
        });
      }
    } catch (_) {}
  }

  void _pick(DiscoveredPrinter d) {
    setState(() {
      _host.text = d.host;
      _serial.text = d.serial;
      if (_name.text.isEmpty) _name.text = d.name;
      if (d.model != null) _model = d.model!;
      _simulator = false;
      _test = null;
    });
  }

  Future<void> _runTest() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    setState(() {
      _busy = true;
      _test = null;
    });
    try {
      final r = await api.testPrinter(
        _host.text.trim(),
        _serial.text.trim(),
        _code.text.trim(),
        id: widget.printer?.id,
      );
      if (mounted) setState(() => _test = r);
    } on ApiException catch (e) {
      if (mounted) setState(() => _test = (ok: false, message: e.message));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    setState(() => _busy = true);
    try {
      await api.savePrinter({
        'name': _name.text.trim().isEmpty ? (_simulator ? 'Simulador' : 'Mi impresora') : _name.text.trim(),
        'model': _model,
        'mode': _simulator ? 'simulator' : 'lan',
        'host': _host.text.trim(),
        'serial': _serial.text.trim(),
        'access_code': _code.text.trim(),
      }, id: widget.printer?.id);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.danger));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final api = context.read<AppState>().api;
    if (api == null || widget.printer == null) return;
    if (!await confirm(
      context,
      title: '¿Quitar ${widget.printer!.name}?',
      message: 'Se quita del servidor. El historial y los archivos se conservan.',
      ok: 'Quitar',
      danger: true,
    )) {
      return;
    }
    await api.deletePrinter(widget.printer!.id);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final available = _found.where((d) => !d.added).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Editar impresora' : 'Agregar impresora'),
        actions: [
          if (_editing)
            IconButton(
              tooltip: 'Quitar',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: _busy ? null : _delete,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          if (!_editing) ...[
            SectionTitle(
              'En tu red',
              trailing: const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            if (available.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _discoveryError ??
                        'Buscando impresoras Bambu Lab… Tienen que estar prendidas y en la misma red que el '
                            'servidor. También podés cargar los datos a mano.',
                    style: TextStyle(color: t.colorScheme.onSurfaceVariant),
                  ),
                ),
              )
            else
              for (final d in available)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: const Icon(Icons.wifi_tethering_rounded, color: AppColors.accent),
                    title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                      '${printerModels[d.model] ?? 'Modelo desconocido'} · ${d.host}'
                      '${d.connection == 'cloud' ? ' · modo nube (activá el modo LAN)' : ''}',
                    ),
                    trailing: _serial.text == d.serial
                        ? const Icon(Icons.check_circle_rounded, color: AppColors.accent)
                        : const Text('Usar'),
                    onTap: () => _pick(d),
                  ),
                ),
          ],
          const SectionTitle('Datos'),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Mi A1'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _model,
            decoration: const InputDecoration(labelText: 'Modelo'),
            items: [for (final e in printerModels.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setState(() => _model = v ?? 'A1'),
          ),
          if (!_simulator) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _host,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'IP de la impresora', hintText: '192.168.1.50'),
              onChanged: (_) => setState(() => _test = null),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _serial,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Número de serie',
                helperText: 'Pantalla de la impresora → Ajustes → Dispositivo',
              ),
              onChanged: (_) => setState(() => _test = null),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              obscureText: !_showCode,
              decoration: InputDecoration(
                labelText: 'Código de acceso',
                helperText: _editing && widget.printer!.hasAccessCode
                    ? 'Dejalo vacío para mantener el guardado'
                    : 'Pantalla de la impresora → Ajustes → WLAN / Modo LAN',
                suffixIcon: IconButton(
                  icon: Icon(_showCode ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                  onPressed: () => setState(() => _showCode = !_showCode),
                ),
              ),
              onChanged: (_) => setState(() => _test = null),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _busy ? null : _runTest,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.network_check_rounded),
              label: const Text('Probar conexión'),
            ),
            if (_test != null)
              Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (_test!.ok ? AppColors.accent : AppColors.danger).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      _test!.ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                      color: _test!.ok ? AppColors.accent : AppColors.danger,
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_test!.message)),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Impresora de prueba (simulador)'),
            subtitle: const Text('Para probar la app sin una impresora real'),
            value: _simulator,
            onChanged: (v) => setState(() => _simulator = v),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_editing ? 'Guardar cambios' : 'Agregar')),
        ],
      ),
    );
  }
}
