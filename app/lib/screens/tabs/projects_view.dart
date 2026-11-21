import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/print_detail.dart';

const projectColors = ['#2EC27E', '#4EA8FF', '#F5A524', '#F0564A', '#B47CFF', '#FF7AB6', '#5CC8FF', '#9AA4B2'];

/// Lista de proyectos: grupos de impresiones (por ejemplo, las piezas de un armado).
class ProjectsView extends StatefulWidget {
  const ProjectsView({super.key});

  @override
  State<ProjectsView> createState() => _ProjectsViewState();
}

class _ProjectsViewState extends State<ProjectsView> {
  List<Project>? _items;
  bool _archived = false;
  int _version = -1;

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final items = await api.projects(archived: _archived);
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
    final t = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: LayoutBuilder(
        builder: (context, c) {
          final cols = (c.maxWidth / 380).floor().clamp(1, 4);
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      FilterChip(
                        label: const Text('Ver archivados'),
                        selected: _archived,
                        onSelected: (v) {
                          _archived = v;
                          _load();
                        },
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
                        onPressed: () async {
                          if (await editProject(context) != null) _load();
                        },
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Nuevo proyecto'),
                      ),
                    ],
                  ),
                ),
              ),
              if (items == null)
                const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
              else if (items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Agrupá impresiones en proyectos (por ejemplo, las piezas de un mueble o un pedido) '
                        'para ver el avance, el filamento y el costo total.\n\n'
                        'Elegí el proyecto al imprimir o desde el detalle de cada impresión.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: t.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      mainAxisExtent: 172,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => _ProjectCard(project: items[i], onChanged: _load),
                      childCount: items.length,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  final Project project;
  final VoidCallback onChanged;
  const _ProjectCard({required this.project, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = parseHex(project.color) ?? AppColors.accent;
    final muted = t.colorScheme.onSurfaceVariant;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => ProjectScreen(project: project)));
          onChanged();
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 6, color: color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            project.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                          ),
                        ),
                        if (project.printing > 0)
                          const StateChip(state: 'RUNNING', label: 'Imprimiendo')
                        else if (project.queued > 0)
                          StateChip(state: 'PREPARE', label: '${project.queued} en cola'),
                      ],
                    ),
                    if (project.notes.isNotEmpty)
                      Text(
                        project.notes,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    const Spacer(),
                    if (project.target != null) ...[
                      Row(
                        children: [
                          Text(
                            '${project.ok} de ${project.target} piezas',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          Text(
                            '${project.progress ?? 0}%',
                            style: TextStyle(color: color, fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          value: (project.progress ?? 0) / 100,
                          minHeight: 7,
                          color: color,
                          backgroundColor: t.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    DefaultTextStyle.merge(
                      style: t.textTheme.labelMedium?.copyWith(color: muted),
                      child: Wrap(
                        spacing: 12,
                        children: [
                          Text('${project.prints} impresiones'),
                          Text('${project.hours.toStringAsFixed(1)} h'),
                          Text(grams(project.grams)),
                          if (project.cost + project.energyCost > 0) Text(money(project.cost + project.energyCost)),
                        ],
                      ),
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

/// Crear o editar un proyecto. Devuelve el proyecto guardado.
Future<Project?> editProject(BuildContext context, {Project? project}) async {
  final name = TextEditingController(text: project?.name ?? '');
  final notes = TextEditingController(text: project?.notes ?? '');
  final target = TextEditingController(text: project?.target?.toString() ?? '');
  var color = project?.color ?? projectColors.first;
  return showDialog<Project>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setS) => AlertDialog(
        title: Text(project == null ? 'Nuevo proyecto' : 'Editar proyecto'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: project == null,
                decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Ej. Organizador de cajones'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: target,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Piezas a imprimir (opcional)',
                  helperText: 'Para ver el avance del proyecto',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notes,
                decoration: const InputDecoration(labelText: 'Notas'),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: [
                  for (final hex in projectColors)
                    GestureDetector(
                      onTap: () => setS(() => color = hex),
                      child: CircleAvatar(
                        radius: 15,
                        backgroundColor: parseHex(hex),
                        child: color == hex ? const Icon(Icons.check_rounded, size: 18, color: Colors.black) : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () async {
              if (name.text.trim().isEmpty) return;
              final api = c.read<AppState>().api;
              if (api == null) return;
              final t = int.tryParse(target.text.trim());
              try {
                final p = await api.saveProject({
                  'name': name.text.trim(),
                  'notes': notes.text.trim(),
                  'color': color,
                  'target': t != null && t > 0 ? t : null,
                }, id: project?.id);
                if (c.mounted) Navigator.pop(c, p);
              } catch (e) {
                if (c.mounted) {
                  ScaffoldMessenger.of(c)
                      .showSnackBar(SnackBar(content: Text('$e'), backgroundColor: AppColors.danger));
                }
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    ),
  );
}

/// Detalle de un proyecto: avance, totales e impresiones.
class ProjectScreen extends StatefulWidget {
  final Project project;
  const ProjectScreen({super.key, required this.project});

  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  late Project p = widget.project;
  List<PrintRecord>? _prints;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final list = await api.history(projectId: p.id);
      final all = await api.projects(archived: true);
      if (!mounted) return;
      setState(() {
        _prints = list;
        p = all.firstWhere((x) => x.id == p.id, orElse: () => p);
      });
    } catch (_) {
      if (mounted) setState(() => _prints ??= []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = parseHex(p.color) ?? AppColors.accent;
    final api = context.read<AppState>().api;
    final prints = _prints;
    return Scaffold(
      appBar: AppBar(
        title: Text(p.name),
        actions: [
          IconButton(
            tooltip: 'Editar',
            icon: const Icon(Icons.edit_rounded),
            onPressed: () async {
              if (await editProject(context, project: p) != null) _load();
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (api == null) return;
              if (v == 'archive') {
                await api.saveProject({'archived': !p.archived}, id: p.id);
                _load();
              } else if (v == 'delete') {
                final ok = await confirm(
                  context,
                  title: 'Borrar proyecto',
                  message: 'Las impresiones quedan en el historial, sin proyecto.',
                  ok: 'Borrar',
                  danger: true,
                );
                if (!ok) return;
                await api.deleteProject(p.id);
                if (context.mounted) Navigator.pop(context);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'archive', child: Text(p.archived ? 'Desarchivar' : 'Archivar')),
              const PopupMenuItem(value: 'delete', child: Text('Borrar')),
            ],
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (p.notes.isNotEmpty) ...[
                          Text(p.notes, style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
                          const SizedBox(height: 14),
                        ],
                        if (p.target != null) ...[
                          Row(
                            children: [
                              Text(
                                '${p.ok} de ${p.target} piezas listas',
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                              ),
                              const Spacer(),
                              Text(
                                '${p.progress ?? 0}%',
                                style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 18),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(99),
                            child: LinearProgressIndicator(
                              value: (p.progress ?? 0) / 100,
                              minHeight: 10,
                              color: color,
                              backgroundColor: t.colorScheme.surfaceContainerHighest,
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        Row(
                          children: [
                            Stat(icon: Icons.print_rounded, label: 'Impresiones', value: '${p.prints}'),
                            Stat(icon: Icons.verified_rounded, label: 'Buenas', value: '${p.ok}'),
                            Stat(icon: Icons.cancel_outlined, label: 'Fallidas', value: '${p.failed}'),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Stat(icon: Icons.schedule_rounded, label: 'Horas', value: p.hours.toStringAsFixed(1)),
                            Stat(icon: Icons.scale_rounded, label: 'Filamento', value: grams(p.grams)),
                            Stat(
                              icon: Icons.payments_outlined,
                              label: 'Costo total',
                              value: money(p.cost + p.energyCost),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                SectionTitle('Impresiones${p.queued > 0 ? ' · ${p.queued} en cola' : ''}'),
                if (prints == null)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (prints.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Todavía no hay impresiones. Elegí este proyecto al imprimir, o asignalo desde el detalle '
                      'de una impresión del historial.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: t.colorScheme.onSurfaceVariant),
                    ),
                  )
                else
                  for (final r in prints)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        onTap: () => showPrintDetail(context, r, _load),
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 52,
                            height: 52,
                            child: r.snapshot && api != null
                                ? Image.network(api.historySnapshot(r.id), fit: BoxFit.cover)
                                : Container(
                                    color: t.colorScheme.surfaceContainer,
                                    child: const Icon(Icons.photo_camera_outlined),
                                  ),
                          ),
                        ),
                        title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${formatClock(r.started)} · ${formatDuration(r.duration.inMinutes)}'
                          '${r.weightG != null ? ' · ${grams(r.weightG!)}' : ''}',
                        ),
                        trailing: r.rating != null
                            ? Icon(
                                r.rating == 'good' ? Icons.thumb_up_rounded : Icons.thumb_down_rounded,
                                color: r.rating == 'good' ? AppColors.accent : AppColors.danger,
                              )
                            : Text(
                                r.status == 'printing' ? 'Imprimiendo' : r.statusLabel,
                                style: TextStyle(color: printStatusColor(r.status)),
                              ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
