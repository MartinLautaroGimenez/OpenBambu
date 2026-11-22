import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/power_card.dart';
import '../maintenance_screen.dart';

class ControlTab extends StatelessWidget {
  final Printer printer;
  const ControlTab({super.key, required this.printer});

  @override
  Widget build(BuildContext context) {
    final s = printer.status;
    final caps = printer.caps;
    final busy = s.isActive;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        const SectionTitle('Energía'),
        PowerCard(printer: printer),
        const SectionTitle('Mantenimiento'),
        Card(
          child: ListTile(
            leading: const Icon(Icons.build_circle_outlined),
            title: const Text('Tareas de mantenimiento'),
            subtitle: const Text('Lubricar, limpiar y revisar según las horas de uso'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MaintenanceScreen(printerId: printer.id, printerName: printer.name),
              ),
            ),
          ),
        ),
        const SectionTitle('Temperaturas'),
        _TempControl(
          label: 'Boquilla',
          icon: Icons.local_fire_department_rounded,
          color: AppColors.nozzle,
          value: s.temps.nozzle,
          target: s.temps.nozzleTarget,
          max: caps.maxNozzleTemp,
          presets: const {'PLA': 220, 'PETG': 250, 'ABS/ASA': 260, 'TPU': 230},
          onSet: (v) => act(context, (api, id) => api.temperature(id, 'nozzle', v)),
        ),
        const SizedBox(height: 12),
        _TempControl(
          label: 'Cama',
          icon: Icons.grid_on_rounded,
          color: AppColors.bed,
          value: s.temps.bed,
          target: s.temps.bedTarget,
          max: caps.maxBedTemp,
          presets: const {'PLA': 60, 'PETG': 70, 'ABS/ASA': 90, 'TPU': 35},
          onSet: (v) => act(context, (api, id) => api.temperature(id, 'bed', v)),
        ),
        const SectionTitle('Ventiladores y luz'),
        Card(
          child: Column(
            children: [
              _FanSlider(label: 'Capa (pieza)', fan: 'part', value: s.fans.part),
              if (s.fans.aux != null) _FanSlider(label: 'Auxiliar', fan: 'aux', value: s.fans.aux!),
              if (s.fans.chamber != null) _FanSlider(label: 'Cámara', fan: 'chamber', value: s.fans.chamber!),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 18),
                secondary: Icon(
                  s.light ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded,
                  color: s.light ? const Color(0xFFFFD54F) : null,
                ),
                title: const Text('Luz', style: TextStyle(fontWeight: FontWeight.w600)),
                value: s.light,
                onChanged: (v) => act(context, (api, id) => api.light(id, v)),
              ),
            ],
          ),
        ),
        SectionTitle('Movimiento', trailing: busy ? const _LockedHint() : null),
        _JogPad(enabled: !busy && !s.isOffline),
        SectionTitle('Filamento', trailing: busy ? const _LockedHint() : null),
        _Extruder(enabled: !busy && !s.isOffline, nozzle: s.temps.nozzle),
        SectionTitle('Consola G-code', trailing: busy ? const _LockedHint() : null),
        _GcodeConsole(enabled: !busy && !s.isOffline),
      ],
    );
  }
}

class _LockedHint extends StatelessWidget {
  const _LockedHint();
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.lock_rounded, size: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
      const SizedBox(width: 4),
      Text('bloqueado al imprimir', style: Theme.of(context).textTheme.labelSmall),
    ],
  );
}

class _TempControl extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final double value, target;
  final int max;
  final Map<String, int> presets;
  final ValueChanged<int> onSet;

  const _TempControl({
    required this.label,
    required this.icon,
    required this.color,
    required this.value,
    required this.target,
    required this.max,
    required this.presets,
    required this.onSet,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ratio = target > 0 ? (value / target).clamp(0.0, 1.0) : 0.0;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _openSheet(context),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: target > 0 ? ratio : 0,
                      strokeWidth: 5,
                      color: color,
                      backgroundColor: t.colorScheme.surfaceContainerHighest,
                    ),
                    Icon(icon, color: color),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${value.toStringAsFixed(0)}°',
                            style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          TextSpan(
                            text: target > 0 ? '  /  ${target.round()}°' : '  /  apagado',
                            style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(onPressed: () => _openSheet(context), icon: const Icon(Icons.edit_rounded)),
            ],
          ),
        ),
      ),
    );
  }

  void _openSheet(BuildContext context) {
    double v = target > 0 ? target : presets.values.first.toDouble();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Temperatura de ${label.toLowerCase()}',
                  style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 20),
                Center(
                  child: Text(
                    '${v.round()} °C',
                    style: Theme.of(c).textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w700, color: color),
                  ),
                ),
                Slider(
                  value: v.clamp(0, max.toDouble()),
                  min: 0,
                  max: max.toDouble(),
                  divisions: max ~/ 5,
                  activeColor: color,
                  onChanged: (x) => set(() => v = x),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final e in presets.entries)
                      ActionChip(
                        label: Text('${e.key} ${e.value}°'),
                        onPressed: () => set(() => v = e.value.toDouble()),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          Navigator.pop(c);
                          onSet(0);
                        },
                        child: const Text('Apagar'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          Navigator.pop(c);
                          onSet(v.round());
                        },
                        child: const Text('Aplicar'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FanSlider extends StatefulWidget {
  final String label;
  final String fan;
  final int value;
  const _FanSlider({required this.label, required this.fan, required this.value});

  @override
  State<_FanSlider> createState() => _FanSliderState();
}

class _FanSliderState extends State<_FanSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final v = _drag ?? widget.value.toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.wind_power_rounded, color: AppColors.fan, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(widget.label, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Text('${v.round()}%', style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          Slider(
            value: v,
            max: 100,
            divisions: 10,
            activeColor: AppColors.fan,
            onChanged: (x) => setState(() => _drag = x),
            onChangeEnd: (x) async {
              await act(context, (api, id) => api.fan(id, widget.fan, x.round()));
              if (mounted) setState(() => _drag = null);
            },
          ),
        ],
      ),
    );
  }
}

class _JogPad extends StatefulWidget {
  final bool enabled;
  const _JogPad({required this.enabled});

  @override
  State<_JogPad> createState() => _JogPadState();
}

class _JogPadState extends State<_JogPad> {
  double _step = 10;

  void _move(String axis, double sign) => act(context, (api, id) => api.move(id, axis, _step * sign));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget btn(IconData icon, VoidCallback f, {String? tip}) => IconButton.filledTonal(
      tooltip: tip,
      iconSize: 26,
      style: IconButton.styleFrom(minimumSize: const Size(54, 54)),
      onPressed: widget.enabled ? f : null,
      icon: Icon(icon),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SegmentedButton<double>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 1, label: Text('1 mm')),
                ButtonSegment(value: 10, label: Text('10 mm')),
                ButtonSegment(value: 50, label: Text('50 mm')),
              ],
              selected: {_step},
              onSelectionChanged: widget.enabled ? (v) => setState(() => _step = v.first) : null,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // XY
                Column(
                  children: [
                    btn(Icons.keyboard_arrow_up_rounded, () => _move('Y', 1), tip: 'Y+'),
                    Row(
                      children: [
                        btn(Icons.keyboard_arrow_left_rounded, () => _move('X', -1), tip: 'X-'),
                        const SizedBox(width: 6),
                        IconButton.filled(
                          tooltip: 'Home (todos los ejes)',
                          style: IconButton.styleFrom(minimumSize: const Size(54, 54)),
                          onPressed: widget.enabled
                              ? () async {
                                  if (await confirm(
                                    context,
                                    title: 'Hacer home',
                                    message: 'La impresora va a mover todos los ejes a su posición de origen.',
                                    ok: 'Home',
                                  )) {
                                    if (context.mounted) act(context, (api, id) => api.home(id));
                                  }
                                }
                              : null,
                          icon: const Icon(Icons.home_rounded),
                        ),
                        const SizedBox(width: 6),
                        btn(Icons.keyboard_arrow_right_rounded, () => _move('X', 1), tip: 'X+'),
                      ],
                    ),
                    btn(Icons.keyboard_arrow_down_rounded, () => _move('Y', -1), tip: 'Y-'),
                    const SizedBox(height: 4),
                    Text('X / Y', style: t.textTheme.labelSmall),
                  ],
                ),
                // Z
                Column(
                  children: [
                    btn(Icons.arrow_upward_rounded, () => _move('Z', 1), tip: 'Z+'),
                    const SizedBox(height: 60),
                    btn(Icons.arrow_downward_rounded, () => _move('Z', -1), tip: 'Z−'),
                    const SizedBox(height: 4),
                    Text('Z', style: t.textTheme.labelSmall),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Extruder extends StatelessWidget {
  final bool enabled;
  final double nozzle;
  const _Extruder({required this.enabled, required this.nozzle});

  @override
  Widget build(BuildContext context) {
    final hot = nozzle >= 170;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!hot)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Calentá la boquilla a más de 170 °C para extruir o retraer.',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: enabled && hot ? () => act(context, (api, id) => api.extrude(id, -10)) : null,
                    icon: const Icon(Icons.arrow_upward_rounded),
                    label: const Text('Retraer 10'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                    onPressed: enabled && hot ? () => act(context, (api, id) => api.extrude(id, 10)) : null,
                    icon: const Icon(Icons.arrow_downward_rounded),
                    label: const Text('Extruir 10'),
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

class _GcodeConsole extends StatefulWidget {
  final bool enabled;
  const _GcodeConsole({required this.enabled});

  @override
  State<_GcodeConsole> createState() => _GcodeConsoleState();
}

class _GcodeConsoleState extends State<_GcodeConsole> {
  final _ctrl = TextEditingController();
  final List<String> _history = [];

  Future<void> _send() async {
    final g = _ctrl.text.trim();
    if (g.isEmpty) return;
    final ok = await act(context, (api, id) => api.gcode(id, g));
    if (ok && mounted) {
      setState(() {
        _history.insert(0, g);
        _ctrl.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _ctrl,
              enabled: widget.enabled,
              style: const TextStyle(fontFamily: 'monospace'),
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'Ej: M104 S200',
                suffixIcon: IconButton(icon: const Icon(Icons.send_rounded), onPressed: widget.enabled ? _send : null),
              ),
              onSubmitted: (_) => _send(),
            ),
            const SizedBox(height: 8),
            Text(
              'Usalo con cuidado: los comandos se envían directo a la impresora.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            for (final h in _history.take(5))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('› $h', style: t.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
              ),
          ],
        ),
      ),
    );
  }
}
