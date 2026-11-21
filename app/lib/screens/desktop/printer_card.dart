import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/camera_view.dart';
import '../../widgets/common.dart';

/// Tamaño de las tarjetas de la grilla de impresoras.
enum CardSize { compact, normal, large }

/// Tarjeta de una impresora para el panel de escritorio: cámara, estado,
/// progreso, temperaturas, AMS, próximo trabajo y controles rápidos.
class PrinterCard extends StatelessWidget {
  final Printer printer;
  final CardSize size;
  final VoidCallback onOpen;
  const PrinterCard({super.key, required this.printer, required this.onOpen, this.size = CardSize.normal});

  Future<void> _run(BuildContext context, Future<void> Function(ApiClient api) fn, {String? ok}) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      await fn(api);
      if (ok != null) messenger.showSnackBar(SnackBar(content: Text(ok), duration: const Duration(seconds: 2)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.danger));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e'), backgroundColor: AppColors.danger));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = printer.status;
    final queue = context.select<AppState, QueueState>((a) => a.queueOf(printer.id));
    final next = queue.pending.where((j) => j.isQueued).firstOrNull;
    final color = stateColor(s.state);
    final muted = t.colorScheme.onSurfaceVariant;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: s.hms.isNotEmpty || queue.waitingBedClear
              ? AppColors.warning.withValues(alpha: 0.6)
              : t.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Encabezado
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 10),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.print_rounded, size: 19, color: color),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          printer.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                        ),
                        Text(
                          [
                            printer.modelLabel,
                            if (printer.mode == 'simulator') 'demo',
                            if (s.wifi != null) s.wifi!,
                          ].join(' · '),
                          style: t.textTheme.labelSmall?.copyWith(color: muted),
                        ),
                      ],
                    ),
                  ),
                  StateChip(state: s.state, label: s.stateLabel),
                  PopupMenuButton<String>(
                    tooltip: 'Más',
                    icon: Icon(Icons.more_vert_rounded, color: muted),
                    onSelected: (v) {
                      if (v == 'open') onOpen();
                      if (v == 'refresh') _run(context, (a) => a.refresh(printer.id));
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'open', child: Text('Abrir panel completo')),
                      PopupMenuItem(value: 'refresh', child: Text('Actualizar estado')),
                    ],
                  ),
                ],
              ),
            ),
            // Cámara con el progreso encima
            if (size != CardSize.compact)
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: Colors.black),
                    if (!s.isOffline)
                      CameraView(printerId: printer.id)
                    else
                      Center(child: Icon(Icons.videocam_off_rounded, color: t.colorScheme.outline, size: 32)),
                    if (s.isActive)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(12, 18, 12, 8),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black87],
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  s.stageLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                                ),
                              ),
                              Text(
                                '${s.job.progress}%',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 20),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (s.isActive) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            s.job.name ?? 'Imprimiendo',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (size == CardSize.compact)
                          Text('${s.job.progress}%', style: const TextStyle(fontWeight: FontWeight.w900)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: s.job.progress / 100,
                        minHeight: 6,
                        color: color,
                        backgroundColor: t.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DefaultTextStyle.merge(
                      style: t.textTheme.labelMedium?.copyWith(color: muted),
                      child: Row(
                        children: [
                          Text('Capa ${s.job.layer}/${s.job.totalLayers}'),
                          const Spacer(),
                          Text(formatDuration(s.job.remainingMin)),
                          if (s.job.eta != null) ...[const Text('  ·  '), Text('fin ${formatClock(s.job.eta!)}')],
                        ],
                      ),
                    ),
                  ] else
                    Text(
                      s.isOffline
                          ? 'Sin conexión con la impresora'
                          : queue.waitingBedClear
                          ? 'Esperando que confirmes cama libre'
                          : 'Lista para imprimir',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: queue.waitingBedClear ? AppColors.warning : muted,
                      ),
                    ),
                  const SizedBox(height: 12),
                  _TempsRow(status: s, caps: printer.caps),
                  if (s.ams.isNotEmpty || s.externalSpool != null) ...[
                    const SizedBox(height: 12),
                    _AmsStrip(status: s),
                  ],
                  if (s.hms.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.warning),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            s.hms.first.description ?? 'Alerta ${s.hms.first.code}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: t.textTheme.labelMedium?.copyWith(color: AppColors.warning),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (next != null) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(next.isScheduled ? Icons.event_rounded : Icons.queue_rounded, size: 15, color: muted),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Siguiente: ${next.name}'
                            '${next.isScheduled ? ' · ${formatClock(next.startAfter!.toLocal())}' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.textTheme.labelMedium?.copyWith(color: muted),
                          ),
                        ),
                        if (queue.pending.length > 1)
                          Text('+${queue.pending.length - 1}', style: t.textTheme.labelMedium?.copyWith(color: muted)),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            // Controles rápidos
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                children: [
                  if (s.isPrinting)
                    _Action(
                      icon: Icons.pause_rounded,
                      tooltip: 'Pausar',
                      onTap: () => _run(context, (a) => a.pause(printer.id)),
                    )
                  else
                    _Action(
                      icon: Icons.play_arrow_rounded,
                      tooltip: 'Reanudar',
                      onTap: s.isPaused ? () => _run(context, (a) => a.resume(printer.id)) : null,
                    ),
                  _Action(
                    icon: Icons.stop_rounded,
                    tooltip: 'Detener',
                    color: AppColors.danger,
                    onTap: s.isActive
                        ? () async {
                            final ok = await confirm(
                              context,
                              title: 'Detener impresión',
                              message: '¿Cancelar "${s.job.name ?? 'la impresión'}" en ${printer.name}?',
                              ok: 'Detener',
                              danger: true,
                            );
                            if (ok && context.mounted) _run(context, (a) => a.stop(printer.id));
                          }
                        : null,
                  ),
                  _Action(
                    icon: s.light ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded,
                    tooltip: s.light ? 'Apagar luz' : 'Prender luz',
                    color: s.light ? AppColors.bed : null,
                    onTap: s.isOffline ? null : () => _run(context, (a) => a.light(printer.id, !s.light)),
                  ),
                  if (queue.waitingBedClear)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: AppColors.warning),
                        onPressed: () => _run(context, (a) async {
                          context.read<AppState>().setQueue(printer.id, await a.bedClear(printer.id));
                        }, ok: 'Cama libre: arranca el siguiente trabajo'),
                        icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                        label: const Text('Cama libre'),
                      ),
                    ),
                  const Spacer(),
                  TextButton(onPressed: onOpen, child: const Text('Panel')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? color;
  const _Action({required this.icon, required this.tooltip, this.onTap, this.color});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    icon: Icon(icon, color: onTap == null ? null : color),
  );
}

class _TempsRow extends StatelessWidget {
  final PrinterStatus status;
  final Capabilities caps;
  const _TempsRow({required this.status, required this.caps});

  @override
  Widget build(BuildContext context) {
    final tp = status.temps;
    String fmt(double v, double target) => target > 0 ? '${v.round()}/${target.round()}°' : '${v.round()}°';
    return Row(
      children: [
        _Pill(
          icon: Icons.local_fire_department_rounded,
          color: AppColors.nozzle,
          text: fmt(tp.nozzle, tp.nozzleTarget),
        ),
        const SizedBox(width: 6),
        _Pill(icon: Icons.grid_on_rounded, color: AppColors.bed, text: fmt(tp.bed, tp.bedTarget)),
        if (tp.chamber != null) ...[
          const SizedBox(width: 6),
          _Pill(icon: Icons.thermostat_rounded, color: AppColors.info, text: '${tp.chamber!.round()}°'),
        ],
        const SizedBox(width: 6),
        _Pill(icon: Icons.air_rounded, color: AppColors.fan, text: '${status.fans.part}%'),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _Pill({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) => Flexible(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Bandejas del AMS como muestras de color, con la activa resaltada.
class _AmsStrip extends StatelessWidget {
  final PrinterStatus status;
  const _AmsStrip({required this.status});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final trays = [
      for (final u in status.ams) ...u.trays.map((tr) => (tr, 'A${tr.id + 1}')),
      if (status.externalSpool != null) (status.externalSpool!, 'Ext'),
    ];
    return Row(
      children: [
        for (final (tr, label) in trays)
          Expanded(
            child: Tooltip(
              message: tr.loaded
                  ? '$label · ${tr.name ?? tr.type ?? ''}${tr.remain >= 0 ? ' · ${tr.remain}%' : ''}'
                  : '$label · vacía',
              child: Container(
                height: 38,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  color: tr.loaded ? (parseHex(tr.color) ?? Colors.grey) : t.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: tr.active ? t.colorScheme.onSurface : t.colorScheme.outlineVariant.withValues(alpha: 0.4),
                    width: tr.active ? 2.2 : 1,
                  ),
                ),
                alignment: Alignment.center,
                child: Builder(
                  builder: (_) {
                    final c = parseHex(tr.color) ?? Colors.grey;
                    final fg = !tr.loaded
                        ? t.colorScheme.outline
                        : (c.computeLuminance() > 0.5 ? Colors.black87 : Colors.white);
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          tr.loaded ? (tr.type ?? '?') : '—',
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 11),
                        ),
                        Text(label, style: TextStyle(color: fg.withValues(alpha: 0.75), fontSize: 9.5)),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
      ],
    );
  }
}
