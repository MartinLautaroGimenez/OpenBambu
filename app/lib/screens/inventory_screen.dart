import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'tabs/activity_tab.dart' show money, grams;
import '../widgets/spool_qr.dart';
import 'tabs/ams_tab.dart' show filamentTypes, swatches;

String trayLabel(int? tray) => tray == null ? 'Sin asignar' : (tray == 254 ? 'Externo' : 'A${tray % 4 + 1}');

/// Inventario de carretes de filamento.
class InventoryScreen extends StatelessWidget {
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final spools = s.spools;
    final t = Theme.of(context);
    final total = spools.fold<double>(0, (a, b) => a + b.remainingG);
    final value = spools.fold<double>(0, (a, b) => a + b.remainingG * b.pricePerGram);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventario de filamento'),
        actions: [
          IconButton(
            tooltip: 'Escanear etiqueta',
            icon: const Icon(Icons.qr_code_scanner_rounded),
            onPressed: () async {
              final spool = await scanSpool(context);
              if (spool != null && context.mounted) editSpool(context, spool: spool);
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => editSpool(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Agregar carrete'),
      ),
      body: RefreshIndicator(
        onRefresh: s.refreshSpools,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
          children: [
            if (spools.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '${spools.length} carretes · ${grams(total)} disponibles · ${money(value)} en filamento',
                  style: TextStyle(color: t.colorScheme.onSurfaceVariant),
                ),
              ),
            if (spools.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Cargá tus carretes con su precio y asignalos a las bandejas del AMS. '
                  'Cada impresión descuenta los gramos usados y calcula el costo.',
                  textAlign: TextAlign.center,
                ),
              ),
            for (final sp in spools) _SpoolCard(spool: sp),
          ],
        ),
      ),
    );
  }
}

class _SpoolCard extends StatelessWidget {
  final Spool spool;
  const _SpoolCard({required this.spool});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final low = spool.remainingG < 100;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => editSpool(context, spool: spool),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(radius: 22, backgroundColor: parseHex(spool.color) ?? Colors.grey),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      spool.label.isEmpty ? spool.material : spool.label,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: spool.fraction,
                        minHeight: 7,
                        color: low ? AppColors.warning : AppColors.accent,
                        backgroundColor: t.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${grams(spool.remainingG)} de ${grams(spool.weightG)}'
                      '${spool.price > 0 ? ' · ${money(spool.price)}' : ''}',
                      style: t.textTheme.bodySmall?.copyWith(
                        color: low ? AppColors.warning : t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Etiqueta QR',
                onPressed: () => showSpoolLabel(context, spool),
                icon: const Icon(Icons.qr_code_2_rounded),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: spool.tray == null
                      ? t.colorScheme.surfaceContainerHigh
                      : AppColors.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  trayLabel(spool.tray),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: spool.tray == null ? null : AppColors.accent,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Alta o edición de un carrete. Con [tray] preasigna esa bandeja.
Future<void> editSpool(BuildContext context, {Spool? spool, int? tray}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SpoolForm(spool: spool, tray: tray ?? spool?.tray),
  );
}

class _SpoolForm extends StatefulWidget {
  final Spool? spool;
  final int? tray;
  const _SpoolForm({this.spool, this.tray});

  @override
  State<_SpoolForm> createState() => _SpoolFormState();
}

class _SpoolFormState extends State<_SpoolForm> {
  late final _brand = TextEditingController(text: widget.spool?.brand ?? '');
  late final _colorName = TextEditingController(text: widget.spool?.colorName ?? '');
  late final _weight = TextEditingController(text: (widget.spool?.weightG ?? 1000).round().toString());
  late final _remaining = TextEditingController(text: (widget.spool?.remainingG ?? 1000).round().toString());
  late final _price = TextEditingController(text: widget.spool == null ? '' : widget.spool!.price.round().toString());
  late String _material = filamentTypes.contains(widget.spool?.material) ? widget.spool!.material : 'PLA';
  late String _color = (widget.spool?.color ?? '#FFFFFF').substring(1).toUpperCase();
  late int? _tray = widget.tray;
  bool _busy = false;

  Future<void> _save() async {
    final s = context.read<AppState>();
    final api = s.api;
    if (api == null) return;
    final data = <String, dynamic>{
      'brand': _brand.text.trim(),
      'material': _material,
      'color': '#$_color',
      'color_name': _colorName.text.trim(),
      'weight_g': double.tryParse(_weight.text) ?? 1000,
      'remaining_g': double.tryParse(_remaining.text) ?? 1000,
      'price': double.tryParse(_price.text.replaceAll('.', '').replaceAll(',', '.')) ?? 0,
      'printer_id': s.selected?.id,
      if (_tray != null) 'tray': _tray,
      if (_tray == null && widget.spool != null) 'unassign': true,
    };
    setState(() => _busy = true);
    try {
      widget.spool == null ? await api.addSpool(data) : await api.updateSpool(widget.spool!.id, data);
      await s.refreshSpools();
      if (mounted) Navigator.pop(context);
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
    final printer = context.watch<AppState>().selected;
    final trays = <int>[
      for (final u in printer?.status.ams ?? <AmsUnit>[])
        for (final tr in u.trays) tr.globalId,
      254,
    ];
    InputDecoration dec(String l, {String? suffix}) => InputDecoration(labelText: l, suffixText: suffix);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.spool == null ? 'Nuevo carrete' : 'Editar carrete',
              style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in filamentTypes)
                  ChoiceChip(
                    label: Text(f),
                    selected: f == _material,
                    onSelected: (_) => setState(() => _material = f),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(controller: _brand, decoration: dec('Marca')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(controller: _colorName, decoration: dec('Color (nombre)')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final sw in swatches)
                  GestureDetector(
                    onTap: () => setState(() => _color = sw),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: parseHex('#$sw'),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: sw == _color ? AppColors.accent : Colors.white24,
                          width: sw == _color ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _weight,
                    keyboardType: TextInputType.number,
                    decoration: dec('Peso total', suffix: 'g'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _remaining,
                    keyboardType: TextInputType.number,
                    decoration: dec('Restante', suffix: 'g'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _price,
              keyboardType: TextInputType.number,
              decoration: dec('Precio del carrete', suffix: '\$'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int?>(
              initialValue: trays.contains(_tray) ? _tray : null,
              decoration: dec('Bandeja'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Sin asignar')),
                for (final tr in trays) DropdownMenuItem(value: tr, child: Text(trayLabel(tr))),
              ],
              onChanged: (v) => setState(() => _tray = v),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (widget.spool != null) ...[
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                      onPressed: () async {
                        final s = context.read<AppState>();
                        await s.api?.updateSpool(widget.spool!.id, {'archived': true, 'unassign': true});
                        await s.refreshSpools();
                        if (context.mounted) Navigator.pop(context);
                      },
                      child: const Text('Archivar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: FilledButton(onPressed: _busy ? null : _save, child: const Text('Guardar')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
