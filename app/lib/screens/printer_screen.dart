import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'catalog/catalog_screen.dart';
import 'settings_screen.dart';
import 'tabs/ams_tab.dart';
import 'tabs/control_tab.dart';
import 'tabs/events_tab.dart';
import 'tabs/print_tab.dart';
import 'tabs/status_tab.dart';

class PrinterScreen extends StatefulWidget {
  const PrinterScreen({super.key});

  @override
  State<PrinterScreen> createState() => _PrinterScreenState();
}

class _PrinterScreenState extends State<PrinterScreen> {
  int _tab = 0;
  StreamSubscription? _events;

  @override
  void initState() {
    super.initState();
    // Avisos en pantalla para eventos importantes
    _events = context.read<AppState>().liveEvents.listen((e) {
      if (!mounted || e.type == 'progress') return;
      final color = switch (e.severity) {
        'error' => AppColors.danger,
        'warning' => AppColors.warning,
        'success' => AppColors.accent,
        _ => null,
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: color,
          content: Text(
            '${e.title} · ${e.message}',
            style: color != null ? const TextStyle(color: Colors.black) : null,
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  void _go(int tab) => setState(() => _tab = tab);

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = s.selected;
    final alerts = p?.status.hms.isNotEmpty ?? false;
    final settings = IconButton(
      tooltip: 'Ajustes',
      icon: const Icon(Icons.settings_rounded),
      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
    );

    Widget section(int tab) {
      if (tab == 0) return CatalogScreen(onOpenPrinter: () => _go(2));
      if (p == null) {
        return Scaffold(
          appBar: AppBar(actions: [settings]),
          body: _Empty(state: s),
        );
      }
      return switch (tab) {
        1 => Scaffold(
          appBar: AppBar(titleSpacing: 20, title: const Text('Biblioteca'), actions: [settings]),
          body: PrintTab(printer: p),
        ),
        2 => DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              titleSpacing: 20,
              title: _PrinterTitle(printer: p, multiple: s.printers.length > 1),
              actions: [settings, const SizedBox(width: 4)],
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'Estado'),
                  Tab(text: 'Control'),
                  Tab(text: 'AMS'),
                ],
              ),
            ),
            body: Builder(
              builder: (ctx) => TabBarView(
                children: [
                  StatusTab(printer: p, onOpenControl: () => DefaultTabController.of(ctx).animateTo(1)),
                  ControlTab(printer: p),
                  AmsTab(printer: p),
                ],
              ),
            ),
          ),
        ),
        _ => Scaffold(
          appBar: AppBar(titleSpacing: 20, title: const Text('Actividad'), actions: [settings]),
          body: EventsTab(printer: p),
        ),
      };
    }

    return Scaffold(
      body: Column(
        children: [
          SafeArea(bottom: false, top: _tab == 0, child: const ConnectionBanner()),
          Expanded(
            child: IndexedStack(index: _tab, children: [for (var i = 0; i < 4; i++) section(i)]),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _go,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore_rounded),
            label: 'Explorar',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: p != null && s.queueOf(p.id).waitingBedClear,
              child: const Icon(Icons.folder_outlined),
            ),
            selectedIcon: const Icon(Icons.folder_rounded),
            label: 'Biblioteca',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: p != null && p.status.isActive,
              backgroundColor: AppColors.accent,
              child: const Icon(Icons.print_outlined),
            ),
            selectedIcon: const Icon(Icons.print_rounded),
            label: 'Impresora',
          ),
          NavigationDestination(
            icon: Badge(isLabelVisible: alerts, child: const Icon(Icons.timeline_outlined)),
            selectedIcon: const Icon(Icons.timeline_rounded),
            label: 'Actividad',
          ),
        ],
      ),
    );
  }
}

class _PrinterTitle extends StatelessWidget {
  final Printer printer;
  final bool multiple;
  const _PrinterTitle({required this.printer, required this.multiple});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: Text(printer.name, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(6)),
          child: Text(printer.modelLabel, style: t.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700)),
        ),
        if (printer.mode == 'simulator') ...[
          const SizedBox(width: 6),
          Text('demo', style: t.textTheme.labelSmall?.copyWith(color: AppColors.warning)),
        ],
        if (multiple) const Icon(Icons.expand_more_rounded),
      ],
    );
    if (!multiple) return title;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showModalBottomSheet(
        context: context,
        builder: (c) {
          final s = c.read<AppState>();
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final p in s.printers.values)
                  ListTile(
                    leading: Icon(Icons.print_rounded, color: stateColor(p.status.state)),
                    title: Text(p.name),
                    subtitle: Text('${p.modelLabel} · ${p.status.stateLabel}'),
                    trailing: p.id == printer.id ? const Icon(Icons.check_rounded) : null,
                    onTap: () {
                      s.select(p.id);
                      Navigator.pop(c);
                    },
                  ),
              ],
            ),
          );
        },
      ),
      child: title,
    );
  }
}

class _Empty extends StatelessWidget {
  final AppState state;
  const _Empty({required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.conn == ConnState.connecting) return const Center(child: CircularProgressIndicator());
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.print_disabled_rounded, size: 48),
            const SizedBox(height: 12),
            Text(
              state.conn == ConnState.connected
                  ? 'El servidor no tiene impresoras configuradas.\nRevisá data/config.yaml.'
                  : 'No se pudo conectar con el servidor.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: state.retryNow, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }
}
