import 'package:material_ui/material_ui.dart';

import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../inventory_screen.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/spool_qr.dart';

const filamentTypes = ['PLA', 'PETG', 'ABS', 'ASA', 'TPU', 'PLA-CF', 'PA', 'PC', 'PVA'];
const swatches = [
  'FFFFFF',
  '161616',
  '8E9089',
  'E4002B',
  'FF6A13',
  'FEC600',
  '00AE42',
  '0086D6',
  '0A2989',
  '5E43B7',
  'F55A74',
  '9D432C',
  'D3B7A7',
  'A3D8E1',
  '00FFFF',
  'C0C0C0',
];

class AmsTab extends StatelessWidget {
  final Printer printer;
  const AmsTab({super.key, required this.printer});

  @override
  Widget build(BuildContext context) {
    final s = printer.status;
    final busy = s.isActive;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        if (s.ams.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('No se detectó ningún AMS'),
                subtitle: const Text('Podés usar el carrete externo de abajo.'),
              ),
            ),
          ),
        for (final unit in s.ams) ...[
          SectionTitle(
            printer.model.startsWith('A1')
                ? 'AMS lite${s.ams.length > 1 ? ' ${unit.id + 1}' : ''}'
                : 'AMS ${unit.id + 1}',
            trailing: unit.humidity > 0 && !printer.model.startsWith('A1')
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.water_drop_outlined, size: 14),
                      Text(' Humedad ${unit.humidity}/5', style: Theme.of(context).textTheme.labelSmall),
                    ],
                  )
                : null,
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
              child: Row(
                children: [
                  for (final t in unit.trays)
                    Expanded(
                      child: Column(
                        children: [
                          _Spool(tray: t, label: 'A${t.id + 1}', onTap: () => _trayMenu(context, t, busy)),
                          _InventoryHint(printerId: printer.id, tray: t.globalId),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        if (s.externalSpool != null) ...[
          const SectionTitle('Carrete externo'),
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              leading: _SpoolDot(color: parseHex(s.externalSpool!.color), loaded: s.externalSpool!.loaded, size: 40),
              title: Text(
                s.externalSpool!.loaded ? (s.externalSpool!.name ?? 'Externo') : 'Vacío',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.externalSpool!.active ? 'En uso' : (s.externalSpool!.type ?? 'Sin configurar')),
                  _InventoryHint(printerId: printer.id, tray: 254, alignStart: true),
                ],
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _trayMenu(context, s.externalSpool!, busy),
            ),
          ),
        ],
        const SectionTitle('Acciones'),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const InventoryScreen())),
          icon: const Icon(Icons.inventory_2_rounded),
          label: const Text('Inventario de filamento'),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy || s.ams.isEmpty && s.externalSpool == null
                    ? null
                    : () => act(context, (api, id) => api.amsUnload(id), success: 'Descargando filamento…'),
                icon: const Icon(Icons.eject_rounded),
                label: const Text('Descargar'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                onPressed: () => act(context, (api, id) => api.amsControl(id, 'resume'), success: 'Reintentando…'),
                icon: const Icon(Icons.replay_rounded),
                label: const Text('Reintentar AMS'),
              ),
            ),
          ],
        ),
        if (busy)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Cargar y descargar está bloqueado durante la impresión. '
              'Podés editar el tipo y color de cada bandeja.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
            ),
          ),
      ],
    );
  }

  void _trayMenu(BuildContext context, Tray t, bool busy) {
    final name = t.globalId == 254 ? 'Carrete externo' : 'Bandeja A${t.id + 1}';
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: _SpoolDot(color: parseHex(t.color), loaded: t.loaded, size: 44),
              title: Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(
                [
                  if (t.loaded) t.name ?? t.type ?? '',
                  if (t.tempMin != null) '${t.tempMin}–${t.tempMax} °C',
                  if (t.remain >= 0) '${t.remain}% restante',
                ].where((x) => x.isNotEmpty).join(' · '),
              ),
            ),
            const Divider(),
            ListTile(
              enabled: !busy && t.loaded && !t.active,
              leading: const Icon(Icons.login_rounded),
              title: const Text('Cargar este filamento'),
              subtitle: t.active ? const Text('Ya está cargado') : null,
              onTap: () {
                Navigator.pop(c);
                act(context, (api, id) => api.amsLoad(id, t.globalId), success: 'Cargando $name…');
              },
            ),
            Builder(
              builder: (_) {
                final spool = context.read<AppState>().spoolInTray(printer.id, t.globalId);
                return ListTile(
                  leading: const Icon(Icons.inventory_2_rounded),
                  title: Text(spool == null ? 'Asignar carrete del inventario' : 'Carrete: ${spool.label}'),
                  subtitle: spool == null ? null : Text('Quedan ${spool.remainingG.round()} g · tocá para editar'),
                  onTap: () {
                    Navigator.pop(c);
                    _assignSpool(context, t.globalId, spool);
                  },
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner_rounded),
              title: const Text('Escanear etiqueta del carrete'),
              subtitle: const Text('Asigna el carrete a esta bandeja'),
              onTap: () {
                Navigator.pop(c);
                scanSpoolIntoTray(context, printer.id, t.globalId, name);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Editar tipo y color'),
              onTap: () {
                Navigator.pop(c);
                _editTray(context, t, name);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _assignSpool(BuildContext context, int tray, Spool? current) {
    if (current != null) {
      editSpool(context, spool: current);
      return;
    }
    final free = context.read<AppState>().spools.where((s) => s.tray == null).toList();
    if (free.isEmpty) {
      editSpool(context, tray: tray);
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final sp in free)
              ListTile(
                leading: CircleAvatar(radius: 14, backgroundColor: parseHex(sp.color) ?? Colors.grey),
                title: Text(sp.label.isEmpty ? sp.material : sp.label),
                subtitle: Text('${sp.remainingG.round()} g restantes'),
                onTap: () async {
                  Navigator.pop(c);
                  final s = context.read<AppState>();
                  await s.api?.updateSpool(sp.id, {'tray': tray, 'printer_id': printer.id});
                  await s.refreshSpools();
                },
              ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('Nuevo carrete'),
              onTap: () {
                Navigator.pop(c);
                editSpool(context, tray: tray);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _editTray(BuildContext context, Tray t, String name) {
    var type = filamentTypes.contains(t.type) ? t.type! : 'PLA';
    var color = (t.color ?? '#FFFFFF').substring(1).toUpperCase();
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
                Row(
                  children: [
                    _SpoolDot(color: parseHex('#$color'), loaded: true, size: 40),
                    const SizedBox(width: 14),
                    Text(name, style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 20),
                const Text('Tipo', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final f in filamentTypes)
                      ChoiceChip(label: Text(f), selected: f == type, onSelected: (_) => set(() => type = f)),
                  ],
                ),
                const SizedBox(height: 20),
                const Text('Color', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final sw in swatches)
                      GestureDetector(
                        onTap: () => set(() => color = sw),
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: parseHex('#$sw'),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: sw == color ? AppColors.accent : Colors.white24,
                              width: sw == color ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.pop(c);
                      act(
                        context,
                        (api, id) => api.amsFilament(id, t.globalId, type, '#$color'),
                        success: '$name actualizada',
                      );
                    },
                    child: const Text('Guardar'),
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

class _Spool extends StatelessWidget {
  final Tray tray;
  final String label;
  final VoidCallback onTap;
  const _Spool({required this.tray, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = parseHex(tray.color);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: tray.active ? AppColors.accent : Colors.transparent, width: 2.5),
              ),
              child: _SpoolDot(color: color, loaded: tray.loaded, size: 54, remain: tray.remain),
            ),
            const SizedBox(height: 8),
            Text(label, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            Text(
              tray.loaded ? (tray.type ?? '?') : 'Vacía',
              style: t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            Text(
              tray.active ? 'En uso' : (tray.remain >= 0 ? '${tray.remain}%' : ' '),
              style: t.textTheme.labelSmall?.copyWith(
                color: tray.active
                    ? AppColors.accent
                    : (tray.remain >= 0 && tray.remain < 15 ? AppColors.warning : null),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpoolDot extends StatelessWidget {
  final Color? color;
  final bool loaded;
  final double size;
  final int remain;
  const _SpoolDot({required this.color, required this.loaded, required this.size, this.remain = -1});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (!loaded) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: t.colorScheme.outlineVariant, width: 2),
        ),
        child: Icon(Icons.add_rounded, color: t.colorScheme.outline),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (remain >= 0)
            SizedBox(
              width: size,
              height: size,
              child: CircularProgressIndicator(
                value: remain / 100,
                strokeWidth: 3,
                color: t.colorScheme.onSurface.withValues(alpha: 0.7),
                backgroundColor: t.colorScheme.surfaceContainerHighest,
              ),
            ),
          Container(
            width: size - 10,
            height: size - 10,
            decoration: BoxDecoration(
              color: color ?? Colors.grey,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24),
            ),
            child: Center(
              child: Container(
                width: size * 0.22,
                height: size * 0.22,
                decoration: BoxDecoration(color: t.colorScheme.surfaceContainerLow, shape: BoxShape.circle),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InventoryHint extends StatelessWidget {
  final String printerId;
  final int tray;
  final bool alignStart;
  const _InventoryHint({required this.printerId, required this.tray, this.alignStart = false});

  @override
  Widget build(BuildContext context) {
    final spool = context.watch<AppState>().spoolInTray(printerId, tray);
    if (spool == null) return const SizedBox.shrink();
    final low = spool.remainingG < 100;
    return Text(
      '${spool.remainingG.round()} g',
      textAlign: alignStart ? TextAlign.start : TextAlign.center,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: low ? AppColors.warning : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
