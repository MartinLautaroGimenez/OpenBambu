import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// Enchufe de la impresora vía Home Assistant.
class PowerCard extends StatefulWidget {
  final Printer printer;
  const PowerCard({super.key, required this.printer});

  @override
  State<PowerCard> createState() => _PowerCardState();
}

class _PowerCardState extends State<PowerCard> {
  Map<String, dynamic>? _status;
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final s = await api.powerStatus(widget.printer.id);
      if (mounted) setState(() => _status = s);
    } catch (_) {}
  }

  Future<void> _toggle(bool on) async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    if (!on &&
        !await confirm(
          context,
          title: 'Apagar la impresora',
          message: 'Se corta la energía desde el enchufe de Home Assistant.',
          ok: 'Apagar',
          danger: true,
        )) {
      return;
    }
    setState(() => _busy = true);
    try {
      final s = await api.setPower(widget.printer.id, on);
      if (mounted) setState(() => _status = s);
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
    final s = _status;
    final t = Theme.of(context);
    if (s == null) return const SizedBox.shrink();
    if (s['available'] != true) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.power_rounded),
          title: const Text('Enchufe inteligente'),
          subtitle: const Text('Conectá un enchufe de Home Assistant para prender y apagar la impresora'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () async {
            await showPowerSetup(context, widget.printer);
            _load();
          },
        ),
      );
    }
    final on = s['state'] == 'on';
    final offAt = s['auto_off_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(((s['auto_off_at'] as num) * 1000).round());
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            secondary: Icon(Icons.power_settings_new_rounded, color: on ? AppColors.accent : t.colorScheme.outline),
            title: const Text('Energía', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(
              s['error'] != null
                  ? 'Home Assistant: ${s['error']}'
                  : offAt != null
                  ? 'Se apaga sola ~${formatClock(offAt)} (al enfriarse)'
                  : (on ? 'Encendida' : 'Apagada'),
            ),
            value: on,
            onChanged: _busy || s['error'] != null ? null : _toggle,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () async {
                await showPowerSetup(context, widget.printer);
                _load();
              },
              child: const Text('Configurar'),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showPowerSetup(BuildContext context, Printer printer) => showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  builder: (_) => _PowerSetup(printer: printer),
);

class _PowerSetup extends StatefulWidget {
  final Printer printer;
  const _PowerSetup({required this.printer});

  @override
  State<_PowerSetup> createState() => _PowerSetupState();
}

class _PowerSetupState extends State<_PowerSetup> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  Map<String, dynamic>? _cfg;
  List<Map<String, dynamic>>? _entities;
  String? _entity;
  bool _autoOff = true;
  bool _autoOn = true;
  double _delay = 5;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    final c = await api.powerConfig();
    setState(() {
      _cfg = c;
      _url.text = c['url'] ?? '';
      _entity = (c['entities'] as Map?)?[widget.printer.id];
      _autoOff = c['auto_off'] != false;
      _autoOn = c['auto_on_queue'] != false;
      _delay = ((c['auto_off_delay_min'] ?? 5) as num).toDouble();
    });
    if (c['configured'] == true) _loadEntities();
  }

  Future<void> _loadEntities() async {
    final api = context.read<AppState>().api;
    try {
      final e = await api!.powerEntities();
      if (mounted) setState(() => _entities = e);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _save({bool close = true}) async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final entities = Map<String, dynamic>.from((_cfg?['entities'] as Map?) ?? {});
      if (_entity != null) entities[widget.printer.id] = _entity;
      _cfg = await api.savePowerConfig({
        'url': _url.text.trim(),
        if (_token.text.trim().isNotEmpty) 'token': _token.text.trim(),
        'entities': entities,
        'auto_off': _autoOff,
        'auto_on_queue': _autoOn,
        'auto_off_delay_min': _delay.round(),
      });
      if (close && _entity != null && mounted) {
        Navigator.pop(context);
      } else {
        await _loadEntities();
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (_cfg == null) return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Home Assistant', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              'Creá un token de larga duración en Home Assistant: tu perfil → Seguridad → Tokens de acceso.',
              style: TextStyle(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Dirección', hintText: 'http://homeassistant.local:8123'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _token,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Token de acceso',
                hintText: _cfg!['has_token'] == true ? 'Guardado (dejalo vacío para mantenerlo)' : null,
              ),
            ),
            const SizedBox(height: 10),
            if (_entities == null)
              OutlinedButton(
                onPressed: _busy ? null : () => _save(close: false),
                child: const Text('Conectar y buscar enchufes'),
              )
            else
              DropdownButtonFormField<String>(
                initialValue: _entities!.any((e) => e['entity_id'] == _entity) ? _entity : null,
                isExpanded: true,
                decoration: InputDecoration(labelText: 'Enchufe de ${widget.printer.name}'),
                items: [
                  for (final e in _entities!)
                    DropdownMenuItem(
                      value: e['entity_id'] as String,
                      child: Text('${e['name']} (${e['state']})', overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _entity = v),
              ),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Apagar sola al terminar'),
              subtitle: Text('Cuando la boquilla se enfría, y ${_delay.round()} min después'),
              value: _autoOff,
              onChanged: (v) => setState(() => _autoOff = v),
            ),
            if (_autoOff)
              Slider(
                value: _delay,
                max: 60,
                divisions: 12,
                label: '${_delay.round()} min',
                onChanged: (v) => setState(() => _delay = v),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Prender para la cola'),
              subtitle: const Text('Si hay un trabajo listo y la impresora está apagada'),
              value: _autoOn,
              onChanged: (v) => setState(() => _autoOn = v),
            ),
            if (_error != null) Text(_error!, style: const TextStyle(color: AppColors.danger)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _busy || _entity == null ? null : _save, child: const Text('Guardar')),
          ],
        ),
      ),
    );
  }
}
