import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class MaintenanceScreen extends StatelessWidget {
  final String printerId;
  final String printerName;
  const MaintenanceScreen({super.key, required this.printerId, required this.printerName});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Mantenimiento · $printerName')),
    body: MaintenanceView(printerId: printerId),
  );
}

/// Tareas de mantenimiento de una impresora con su avance en horas de impresión.
class MaintenanceView extends StatefulWidget {
  final String printerId;
  const MaintenanceView({super.key, required this.printerId});

  @override
  State<MaintenanceView> createState() => _MaintenanceViewState();
}

class _MaintenanceViewState extends State<MaintenanceView> {
  MaintenanceOverview? _m;
  String? _error;
  int _version = -1;
  String? _loadedFor;

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final m = await api.maintenance(widget.printerId);
      if (mounted) {
        setState(() {
          _m = m;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _run(Future<MaintenanceOverview> Function() fn) async {
    try {
      final m = await fn();
      if (mounted) setState(() => _m = m);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: AppColors.danger));
      }
    }
  }

  Future<void> _edit([MaintenanceTask? task]) async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    final name = TextEditingController(text: task?.name ?? '');
    final interval = TextEditingController(text: task == null ? '100' : task.intervalH.round().toString());
    final notes = TextEditingController(text: task?.notes ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(task == null ? 'Nueva tarea' : 'Editar tarea'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Tarea', hintText: 'Ej. Cambiar la boquilla'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: interval,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Cada cuántas horas de impresión', suffixText: 'h'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notes,
                decoration: const InputDecoration(labelText: 'Cómo se hace (opcional)'),
              ),
            ],
          ),
        ),
        actions: [
          if (task != null)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              onPressed: () {
                Navigator.pop(c, false);
                _run(() => api.deleteMaintenanceTask(widget.printerId, task.id));
              },
              child: const Text('Borrar'),
            ),
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    final h = double.tryParse(interval.text.replaceAll(',', '.'));
    if (ok != true || name.text.trim().isEmpty || h == null || h <= 0) return;
    await _run(
      () => api.saveMaintenanceTask(widget.printerId, {
        'name': name.text.trim(),
        'interval_h': h,
        'notes': notes.text.trim(),
      }, id: task?.id),
    );
  }

  Future<void> _done(MaintenanceTask task) async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    final ok = await confirm(
      context,
      title: 'Marcar como hecha',
      message: '"${task.name}" vuelve a contar desde ahora.',
      ok: 'Hecha',
    );
    if (ok) await _run(() => api.maintenanceDone(widget.printerId, task.id));
  }

  @override
  Widget build(BuildContext context) {
    final v = context.select<AppState, int>((s) => s.historyVersion);
    if (v != _version || _loadedFor != widget.printerId) {
      _version = v;
      _loadedFor = widget.printerId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final m = _m;
    final t = Theme.of(context);
    if (m == null) {
      return Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Stat(icon: Icons.schedule_rounded, label: 'Horas de impresión', value: m.hours.toStringAsFixed(1)),
                  Stat(
                    icon: Icons.build_circle_outlined,
                    label: 'Pendientes',
                    value: m.due == 0 ? 'Ninguna' : '${m.due}',
                  ),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
                    onPressed: () => _edit(),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Tarea'),
                  ),
                ],
              ),
            ),
          ),
          const SectionTitle('Tareas'),
          for (final task in m.tasks) _TaskCard(task: task, onDone: () => _done(task), onEdit: () => _edit(task)),
          if (m.log.isNotEmpty) ...[
            const SectionTitle('Hecho últimamente'),
            Card(
              child: Column(
                children: [
                  for (final l in m.log.take(10))
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.check_circle_outline_rounded, color: AppColors.accent),
                      title: Text(l.name),
                      subtitle: Text(
                        '${formatClock(l.done)} · a las ${l.hours.toStringAsFixed(0)} h'
                        '${l.notes.isNotEmpty ? ' · ${l.notes}' : ''}',
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'Las horas se cuentan con las impresiones que registró OpenBambu. Los intervalos son orientativos: '
            'ajustalos según el uso y el material (los abrasivos gastan más).',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  final MaintenanceTask task;
  final VoidCallback onDone;
  final VoidCallback onEdit;
  const _TaskCard({required this.task, required this.onDone, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = task.due ? AppColors.danger : (task.soon ? AppColors.warning : AppColors.accent);
    final left = task.hoursLeft;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(task.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (task.notes.isNotEmpty)
                      Text(
                        task.notes,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: task.fraction.clamp(0, 1),
                        minHeight: 6,
                        color: color,
                        backgroundColor: t.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      task.due
                          ? 'Vencida hace ${(-left).toStringAsFixed(left > -10 ? 1 : 0)} h · cada ${task.intervalH.round()} h'
                          : 'Faltan ${left.toStringAsFixed(left < 10 ? 1 : 0)} h · cada ${task.intervalH.round()} h',
                      style: t.textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              task.due
                  ? FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                      onPressed: onDone,
                      child: const Text('Hecha'),
                    )
                  : IconButton(
                      tooltip: 'Marcar como hecha',
                      onPressed: onDone,
                      icon: const Icon(Icons.task_alt_rounded),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
