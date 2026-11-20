import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'settings_screen.dart';
import 'tabs/ams_tab.dart';
import 'tabs/control_tab.dart';
import 'tabs/events_tab.dart';
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

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final p = s.selected;
    final unread = s.events.where((e) => e.severity == 'error').length;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: p == null ? const Text('OpenBambu') : _PrinterTitle(printer: p, multiple: s.printers.length > 1),
        actions: [
          IconButton(
            tooltip: 'Ajustes',
            icon: const Icon(Icons.settings_rounded),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          const ConnectionBanner(),
          Expanded(
            child: p == null
                ? _Empty(state: s)
                : IndexedStack(
                    index: _tab,
                    children: [
                      StatusTab(printer: p, onOpenControl: () => setState(() => _tab = 1)),
                      ControlTab(printer: p),
                      AmsTab(printer: p),
                      EventsTab(printer: p),
                    ],
                  ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard_rounded),
            label: 'Estado',
          ),
          const NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune_rounded),
            label: 'Control',
          ),
          const NavigationDestination(
            icon: Icon(Icons.palette_outlined),
            selectedIcon: Icon(Icons.palette_rounded),
            label: 'AMS',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: unread > 0 && (p?.status.hms.isNotEmpty ?? false),
              child: const Icon(Icons.notifications_outlined),
            ),
            selectedIcon: const Icon(Icons.notifications_rounded),
            label: 'Eventos',
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
