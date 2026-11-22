import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../catalog/catalog_screen.dart';
import '../inventory_screen.dart';
import '../printers_screen.dart';
import '../settings_screen.dart';
import '../tabs/activity_tab.dart';
import '../tabs/ams_tab.dart';
import '../tabs/control_tab.dart';
import '../tabs/events_tab.dart';
import '../maintenance_screen.dart';
import '../tabs/print_tab.dart';
import '../tabs/projects_view.dart';
import '../tabs/status_tab.dart';
import 'archive_page.dart';
import 'printer_card.dart';
import 'queue_page.dart';

enum DeskPage { printers, queue, archive, projects, stats, maintenance, library, explore, filament, events, settings }

class _NavItem {
  final DeskPage page;
  final IconData icon;
  final String label;
  const _NavItem(this.page, this.icon, this.label);
}

const _nav = [
  _NavItem(DeskPage.printers, Icons.print_rounded, 'Impresoras'),
  _NavItem(DeskPage.queue, Icons.queue_rounded, 'Cola'),
  _NavItem(DeskPage.archive, Icons.photo_library_rounded, 'Archivo'),
  _NavItem(DeskPage.projects, Icons.workspaces_rounded, 'Proyectos'),
  _NavItem(DeskPage.stats, Icons.insights_rounded, 'Estadísticas'),
  _NavItem(DeskPage.maintenance, Icons.build_circle_rounded, 'Mantenimiento'),
  _NavItem(DeskPage.library, Icons.folder_rounded, 'Biblioteca'),
  _NavItem(DeskPage.explore, Icons.explore_rounded, 'Explorar'),
  _NavItem(DeskPage.filament, Icons.palette_rounded, 'Filamento'),
  _NavItem(DeskPage.events, Icons.notifications_rounded, 'Eventos'),
];

/// Interfaz de escritorio (navegador o tablet): barra lateral con secciones,
/// grilla de impresoras, cola, archivo, estadísticas y más.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  DeskPage _page = DeskPage.printers;
  String? _detail; // impresora abierta en el panel completo
  bool _collapsed = false;
  CardSize _size = CardSize.normal;
  String _query = '';
  String _filter = 'all';
  String _title = '';

  void _go(DeskPage p) => setState(() {
    _page = p;
    _detail = null;
    _query = '';
  });

  void _openPrinter(String id) {
    context.read<AppState>().select(id);
    setState(() => _detail = id);
  }

  /// Progreso en el título de la pestaña del navegador.
  void _updateTitle(AppState s) {
    final active = s.printers.values.where((p) => p.status.isActive).toList();
    final title = active.isEmpty
        ? 'OpenBambu'
        : active.length == 1
        ? '${active.first.status.job.progress}% · ${active.first.name} — OpenBambu'
        : '${active.length} imprimiendo — OpenBambu';
    if (title == _title) return;
    _title = title;
    SystemChrome.setApplicationSwitcherDescription(
      ApplicationSwitcherDescription(label: title, primaryColor: AppColors.accent.toARGB32()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateTitle(s));
    final width = MediaQuery.sizeOf(context).width;
    final collapsed = _collapsed || width < 1180;

    return Scaffold(
      body: Row(
        children: [
          _Sidebar(
            page: _page,
            collapsed: collapsed,
            onSelect: _go,
            onToggle: width < 1180 ? null : () => setState(() => _collapsed = !_collapsed),
          ),
          VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3)),
          Expanded(
            child: Column(
              children: [
                const ConnectionBanner(),
                Expanded(child: _body(s)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(AppState s) {
    final selected = s.selected;
    if (_page == DeskPage.settings) return const SettingsScreen();
    if (_page == DeskPage.explore) {
      return CatalogScreen(onOpenPrinter: () => _go(DeskPage.printers));
    }
    if (_page == DeskPage.filament) return const InventoryScreen();

    if (_page == DeskPage.printers && _detail != null && s.printers[_detail] != null) {
      return _PrinterDetail(printer: s.printers[_detail]!, onBack: () => setState(() => _detail = null));
    }

    return switch (_page) {
      DeskPage.printers => _Page(
        title: 'Impresoras',
        subtitle: _summary(s),
        actions: [
          _SearchField(hint: 'Buscar impresora', onChanged: (v) => setState(() => _query = v)),
          const SizedBox(width: 10),
          DropdownButton<String>(
            value: _filter,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(12),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('Todas')),
              DropdownMenuItem(value: 'active', child: Text('Imprimiendo')),
              DropdownMenuItem(value: 'idle', child: Text('Libres')),
              DropdownMenuItem(value: 'alert', child: Text('Con alertas')),
              DropdownMenuItem(value: 'offline', child: Text('Desconectadas')),
            ],
            onChanged: (v) => setState(() => _filter = v ?? 'all'),
          ),
          const SizedBox(width: 6),
          SegmentedButton<CardSize>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(
                value: CardSize.compact,
                icon: Icon(Icons.view_agenda_outlined, size: 18),
                tooltip: 'Compactas',
              ),
              ButtonSegment(value: CardSize.normal, icon: Icon(Icons.grid_view_rounded, size: 18), tooltip: 'Normales'),
              ButtonSegment(value: CardSize.large, icon: Icon(Icons.crop_square_rounded, size: 18), tooltip: 'Grandes'),
            ],
            selected: {_size},
            onSelectionChanged: (v) => setState(() => _size = v.first),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrinterFormScreen())),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Agregar'),
          ),
        ],
        child: _printersGrid(s),
      ),
      DeskPage.queue => _Page(
        title: 'Cola de impresión',
        subtitle: 'Entre trabajo y trabajo espera que confirmes la cama libre',
        child: QueuePage(onOpenLibrary: () => _go(DeskPage.library)),
      ),
      DeskPage.archive => _Page(
        title: 'Archivo',
        subtitle: 'Todas las impresiones con su foto final, filamento y costo',
        actions: [_SearchField(hint: 'Buscar impresión', onChanged: (v) => setState(() => _query = v))],
        child: ArchivePage(query: _query),
      ),
      DeskPage.stats => _Page(
        title: 'Estadísticas',
        subtitle: 'De todas las impresoras',
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: StatsView(columns: 3)),
          ),
        ),
      ),
      DeskPage.projects => const _Page(
        title: 'Proyectos',
        subtitle: 'Grupos de impresiones con su avance, filamento y costo total',
        child: Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: ProjectsView()),
      ),
      DeskPage.maintenance when selected != null => _Page(
        title: 'Mantenimiento',
        subtitle: 'Tareas según las horas de impresión de cada impresora',
        actions: [if (s.printers.length > 1) _PrinterPicker(state: s)],
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: MaintenanceView(key: ValueKey(selected.id), printerId: selected.id),
            ),
          ),
        ),
      ),
      DeskPage.library when selected != null => _Page(
        title: 'Biblioteca',
        subtitle: 'Archivos del servidor y de la tarjeta SD',
        actions: [if (s.printers.length > 1) _PrinterPicker(state: s)],
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: PrintTab(key: ValueKey(selected.id), printer: selected),
          ),
        ),
      ),
      DeskPage.events when selected != null => _Page(
        title: 'Eventos',
        subtitle: 'Avisos de inicio, pausa, fin, fallas y errores',
        actions: [if (s.printers.length > 1) _PrinterPicker(state: s)],
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: EventsTab(key: ValueKey(selected.id), printer: selected),
          ),
        ),
      ),
      _ => _Page(
        title: _nav.firstWhere((n) => n.page == _page).label,
        child: _NoPrinters(state: s),
      ),
    };
  }

  String _summary(AppState s) {
    final all = s.printers.values;
    final printing = all.where((p) => p.status.isActive).length;
    final offline = all.where((p) => p.status.isOffline).length;
    return [
      '${all.length} ${all.length == 1 ? 'impresora' : 'impresoras'}',
      if (printing > 0) '$printing imprimiendo',
      if (offline > 0) '$offline sin conexión',
    ].join(' · ');
  }

  Widget _printersGrid(AppState s) {
    if (s.printers.isEmpty) return _NoPrinters(state: s);
    final q = _query.trim().toLowerCase();
    final list = s.printers.values.where((p) {
      if (q.isNotEmpty && !'${p.name} ${p.model} ${p.modelLabel}'.toLowerCase().contains(q)) return false;
      return switch (_filter) {
        'active' => p.status.isActive,
        'idle' => !p.status.isActive && !p.status.isOffline,
        'alert' => p.status.hms.isNotEmpty || s.queueOf(p.id).waitingBedClear,
        'offline' => p.status.isOffline,
        _ => true,
      };
    }).toList();
    if (list.isEmpty) {
      return const Center(child: Text('Ninguna impresora coincide con el filtro.'));
    }
    final maxW = switch (_size) {
      CardSize.compact => 340.0,
      CardSize.normal => 440.0,
      CardSize.large => 640.0,
    };
    return LayoutBuilder(
      builder: (context, c) {
        final cols = ((c.maxWidth - 48 + 16) / (maxW + 16)).ceil().clamp(1, 8);
        final w = (c.maxWidth - 48 - (cols - 1) * 16) / cols;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final p in list)
                SizedBox(
                  width: w,
                  child: PrinterCard(printer: p, size: _size, onOpen: () => _openPrinter(p.id)),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ---- barra lateral ------------------------------------------------------------

class _Sidebar extends StatelessWidget {
  final DeskPage page;
  final bool collapsed;
  final ValueChanged<DeskPage> onSelect;
  final VoidCallback? onToggle;
  const _Sidebar({required this.page, required this.collapsed, required this.onSelect, this.onToggle});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = context.watch<AppState>();
    final alerts = s.printers.values.any((p) => p.status.hms.isNotEmpty);
    final waiting = s.printers.keys.any((id) => s.queueOf(id).waitingBedClear);
    final printing = s.printers.values.where((p) => p.status.isActive).toList();

    Widget item(DeskPage p, IconData icon, String label, {bool badge = false, String? count}) {
      final sel = page == p;
      final fg = sel ? AppColors.accent : t.colorScheme.onSurfaceVariant;
      final tile = Material(
        color: sel ? AppColors.accent.withValues(alpha: 0.13) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onSelect(p),
          child: SizedBox(
            height: 42,
            child: Row(
              mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                if (!collapsed) const SizedBox(width: 12),
                Badge(
                  isLabelVisible: badge,
                  smallSize: 8,
                  child: Icon(icon, size: 21, color: fg),
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: sel ? t.colorScheme.onSurface : t.colorScheme.onSurfaceVariant,
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (count != null)
                    Container(
                      margin: const EdgeInsets.only(right: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        count,
                        style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700, fontSize: 11.5),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: collapsed ? Tooltip(message: label, child: tile) : tile,
      );
    }

    final pendingJobs = s.printers.keys.fold<int>(0, (a, id) => a + s.queueOf(id).pending.length);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: collapsed ? 72 : 232,
      color: t.colorScheme.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Logo
          Padding(
            padding: EdgeInsets.fromLTRB(collapsed ? 0 : 16, 18, 8, 18),
            child: Row(
              mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [AppColors.accent, Color(0xFF1B8F5C)]),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: const Icon(Icons.print_rounded, color: Colors.white, size: 20),
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('OpenBambu', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                  ),
                  if (onToggle != null)
                    IconButton(
                      tooltip: 'Contraer',
                      visualDensity: VisualDensity.compact,
                      onPressed: onToggle,
                      icon: Icon(Icons.keyboard_double_arrow_left_rounded, color: t.colorScheme.onSurfaceVariant),
                    ),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.symmetric(horizontal: collapsed ? 10 : 12),
              children: [
                for (final n in _nav)
                  item(
                    n.page,
                    n.icon,
                    n.label,
                    badge: switch (n.page) {
                      DeskPage.printers => alerts,
                      DeskPage.queue => waiting,
                      _ => false,
                    },
                    count: switch (n.page) {
                      DeskPage.printers when printing.isNotEmpty => '${printing.length}',
                      DeskPage.queue when pendingJobs > 0 => '$pendingJobs',
                      _ => null,
                    },
                  ),
              ],
            ),
          ),
          // Impresiones en curso
          if (!collapsed)
            for (final p in printing.take(3))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text('${p.status.job.progress}%', style: t.textTheme.labelMedium),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: p.status.job.progress / 100,
                        minHeight: 4,
                        color: stateColor(p.status.state),
                        backgroundColor: t.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ),
              ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: collapsed ? 10 : 12),
            child: item(DeskPage.settings, Icons.settings_rounded, 'Ajustes'),
          ),
          if (collapsed && onToggle != null)
            IconButton(
              tooltip: 'Expandir',
              onPressed: onToggle,
              icon: Icon(Icons.keyboard_double_arrow_right_rounded, color: t.colorScheme.onSurfaceVariant),
            ),
          // Estado del servidor
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
            child: Row(
              mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: switch (s.conn) {
                      ConnState.connected => AppColors.accent,
                      ConnState.connecting => AppColors.warning,
                      ConnState.disconnected => AppColors.danger,
                    },
                  ),
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      switch (s.conn) {
                        ConnState.connected => 'Servidor conectado',
                        ConnState.connecting => 'Conectando…',
                        ConnState.disconnected => 'Sin conexión',
                      },
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- piezas comunes -----------------------------------------------------------

class _Page extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget child;
  const _Page({required this.title, required this.child, this.subtitle, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(subtitle!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              ...actions,
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _SearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  const _SearchField({required this.hint, required this.onChanged});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 240,
    height: 42,
    child: TextField(
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        contentPadding: EdgeInsets.zero,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    ),
  );
}

class _PrinterPicker extends StatelessWidget {
  final AppState state;
  const _PrinterPicker({required this.state});

  @override
  Widget build(BuildContext context) => DropdownButton<String>(
    value: state.selected?.id,
    underline: const SizedBox.shrink(),
    borderRadius: BorderRadius.circular(12),
    items: [for (final p in state.printers.values) DropdownMenuItem(value: p.id, child: Text(p.name))],
    onChanged: (v) {
      if (v != null) state.select(v);
    },
  );
}

class _NoPrinters extends StatelessWidget {
  final AppState state;
  const _NoPrinters({required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.conn == ConnState.connecting) return const Center(child: CircularProgressIndicator());
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.print_disabled_rounded, size: 48),
          const SizedBox(height: 12),
          Text(
            state.conn == ConnState.connected
                ? 'Este servidor todavía no tiene impresoras.'
                : 'No se pudo conectar con el servidor.',
          ),
          const SizedBox(height: 16),
          if (state.conn == ConnState.connected)
            FilledButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrinterFormScreen())),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Agregar impresora'),
            )
          else
            OutlinedButton(onPressed: state.retryNow, child: const Text('Reintentar')),
        ],
      ),
    );
  }
}

/// Panel completo de una impresora: estado, control y AMS a la vez.
class _PrinterDetail extends StatelessWidget {
  final Printer printer;
  final VoidCallback onBack;
  const _PrinterDetail({required this.printer, required this.onBack});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget column(String title, Widget child, {int flex = 1}) => Expanded(
      flex: flex,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Text(
              title,
              style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: t.colorScheme.primary),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 24, 10),
          child: Row(
            children: [
              IconButton(tooltip: 'Volver a impresoras', onPressed: onBack, icon: const Icon(Icons.arrow_back_rounded)),
              const SizedBox(width: 4),
              Text(printer.name, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: t.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(printer.modelLabel, style: t.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              StateChip(state: printer.status.state, label: printer.status.stateLabel),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              column('Estado', StatusTab(printer: printer, onOpenControl: () {}), flex: 5),
              const VerticalDivider(width: 1),
              column('Control', ControlTab(printer: printer), flex: 4),
              const VerticalDivider(width: 1),
              column('AMS y filamento', AmsTab(printer: printer), flex: 4),
            ],
          ),
        ),
      ],
    );
  }
}
