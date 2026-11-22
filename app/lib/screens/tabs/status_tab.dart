import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../theme.dart';
import '../../widgets/camera_view.dart';
import '../../widgets/common.dart';
import '../camera_screen.dart';
import '../skip_objects_screen.dart';

class StatusTab extends StatelessWidget {
  final Printer printer;
  final VoidCallback onOpenControl;
  const StatusTab({super.key, required this.printer, required this.onOpenControl});

  @override
  Widget build(BuildContext context) {
    final s = printer.status;
    return RefreshIndicator(
      onRefresh: () => act(context, (api, id) => api.refresh(id)),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          for (final h in s.hms) _HmsBanner(hms: h),
          _CameraCard(printer: printer),
          const SizedBox(height: 14),
          _JobCard(printer: printer),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _TempTile(
                  icon: Icons.local_fire_department_rounded,
                  label: 'Boquilla',
                  value: s.temps.nozzle,
                  target: s.temps.nozzleTarget,
                  color: AppColors.nozzle,
                  onTap: onOpenControl,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _TempTile(
                  icon: Icons.grid_on_rounded,
                  label: 'Cama',
                  value: s.temps.bed,
                  target: s.temps.bedTarget,
                  color: AppColors.bed,
                  onTap: onOpenControl,
                ),
              ),
            ],
          ),
          if (s.isActive) ...[
            const SectionTitle('Velocidad'),
            _SpeedSelector(level: s.speedLevel, percent: s.speedPercent),
          ],
        ],
      ),
    );
  }
}

class _HmsBanner extends StatelessWidget {
  final Hms hms;
  const _HmsBanner({required this.hms});

  @override
  Widget build(BuildContext context) {
    final serious = hms.severity == 'fatal' || hms.severity == 'serious';
    final c = serious ? AppColors.danger : AppColors.warning;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: c),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    serious ? 'Error de la impresora' : 'Aviso de la impresora',
                    style: TextStyle(color: c, fontWeight: FontWeight.w700),
                  ),
                  Text(hms.description ?? 'HMS ${hms.code}', style: const TextStyle(fontSize: 13.5)),
                  const SizedBox(height: 2),
                  Text(
                    'HMS ${hms.code} · más detalles en Actividad → Eventos',
                    style: const TextStyle(fontSize: 11.5, color: Colors.white54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraCard extends StatelessWidget {
  final Printer printer;
  const _CameraCard({required this.printer});

  @override
  Widget build(BuildContext context) {
    final s = printer.status;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (printer.caps.camera == 'tcp_jpeg')
              CameraView(printerId: printer.id)
            else
              const ColoredBox(
                color: Colors.black,
                child: Center(
                  child: Text(
                    'La cámara RTSP de la X1 todavía no está soportada',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            // degradé superior para legibilidad
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 60,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x99000000), Color(0x00000000)],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 10,
              left: 12,
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                    child: const Row(
                      children: [
                        Icon(Icons.circle, color: Color(0xFFFF4B4B), size: 8),
                        SizedBox(width: 5),
                        Text(
                          'EN VIVO',
                          style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: Row(
                children: [
                  _OverlayButton(
                    icon: s.light ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded,
                    tooltip: s.light ? 'Apagar luz' : 'Encender luz',
                    active: s.light,
                    onTap: () => act(context, (api, id) => api.light(id, !s.light)),
                  ),
                  _OverlayButton(
                    icon: Icons.fullscreen_rounded,
                    tooltip: 'Pantalla completa',
                    onTap: () =>
                        Navigator.push(context, MaterialPageRoute(builder: (_) => CameraScreen(printerId: printer.id))),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OverlayButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  const _OverlayButton({required this.icon, required this.tooltip, required this.onTap, this.active = false});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    style: IconButton.styleFrom(backgroundColor: Colors.black45),
    icon: Icon(icon, color: active ? const Color(0xFFFFD54F) : Colors.white),
  );
}

class _JobCard extends StatelessWidget {
  final Printer printer;
  const _JobCard({required this.printer});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = printer.status;
    final job = s.job;
    final hasJob = job.name != null && s.state != 'IDLE';
    final color = stateColor(s.state);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StateChip(state: s.state, label: s.stateLabel),
                const Spacer(),
                if (s.wifi != null)
                  Row(
                    children: [
                      Icon(Icons.wifi_rounded, size: 15, color: t.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(s.wifi!, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              hasJob ? job.name! : 'Sin impresión en curso',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (s.state == 'FAILED' && job.printErrorText != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(job.printErrorText!, style: const TextStyle(color: AppColors.danger)),
              ),
            if (s.isActive && s.stage != 0 && s.stage != -1 && s.stage != 255)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  s.stageLabel,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
              ),
            if (hasJob) ...[
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${job.progress}',
                    style: t.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, height: 1),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4, left: 2),
                    child: Text('%', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: s.state == 'PREPARE' ? null : job.progress / 100,
                  minHeight: 10,
                  color: color,
                  backgroundColor: t.colorScheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Stat(
                    icon: Icons.layers_rounded,
                    label: 'Capa',
                    value: job.totalLayers > 0 ? '${job.layer}/${job.totalLayers}' : '—',
                  ),
                  Stat(icon: Icons.timer_outlined, label: 'Restante', value: formatDuration(job.remainingMin)),
                  Stat(
                    icon: Icons.flag_rounded,
                    label: 'Termina',
                    value: job.eta != null && s.isActive ? formatClock(job.eta!) : '—',
                  ),
                ],
              ),
            ],
            if (s.isActive) ...[
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: s.isPaused
                        ? FilledButton.icon(
                            onPressed: () => act(context, (api, id) => api.resume(id)),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Reanudar'),
                          )
                        : FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                            onPressed: s.state == 'RUNNING' ? () => act(context, (api, id) => api.pause(id)) : null,
                            icon: const Icon(Icons.pause_rounded),
                            label: const Text('Pausar'),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.danger,
                        side: BorderSide(color: AppColors.danger.withValues(alpha: 0.5)),
                      ),
                      onPressed: () async {
                        if (await confirm(
                          context,
                          title: '¿Detener la impresión?',
                          message: 'La impresión de «${job.name ?? ''}» se cancelará y no se puede reanudar.',
                          ok: 'Detener',
                          danger: true,
                        )) {
                          if (context.mounted) await act(context, (api, id) => api.stop(id));
                        }
                      },
                      icon: const Icon(Icons.stop_rounded),
                      label: const Text('Detener'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => SkipObjectsScreen(printerId: printer.id)),
                  ),
                  icon: const Icon(Icons.layers_clear_rounded),
                  label: Text(
                    s.skippedObjects.isEmpty
                        ? 'Omitir objetos'
                        : 'Omitir objetos · ${s.skippedObjects.length} omitido(s)',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TempTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final double value, target;
  final Color color;
  final VoidCallback onTap;
  const _TempTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.target,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: color, size: 18),
                  const SizedBox(width: 6),
                  Text(label, style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 8),
              Text('${value.round()}°', style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              Text(
                target > 0 ? 'Objetivo ${target.round()}°' : 'Apagado',
                style: t.textTheme.labelMedium?.copyWith(color: target > 0 ? color : t.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpeedSelector extends StatelessWidget {
  final int level;
  final int percent;
  const _SpeedSelector({required this.level, required this.percent});

  static const _labels = {1: 'Silencioso', 2: 'Estándar', 3: 'Sport', 4: 'Ludicrous'};
  static const _percents = {1: 50, 2: 100, 3: 124, 4: 166};
  static const _icons = {
    1: Icons.nightlight_round,
    2: Icons.speed_rounded,
    3: Icons.bolt_rounded,
    4: Icons.rocket_launch_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(
      children: [
        for (final e in _labels.entries) ...[
          if (e.key > 1) const SizedBox(width: 8),
          Expanded(
            child: Material(
              color: e.key == level ? AppColors.accent.withValues(alpha: 0.16) : t.colorScheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: e.key == level ? AppColors.accent : t.colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: e.key == level ? null : () => act(context, (api, id) => api.speed(id, e.key)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    children: [
                      Icon(_icons[e.key], color: e.key == level ? AppColors.accent : t.colorScheme.onSurfaceVariant),
                      const SizedBox(height: 4),
                      FittedBox(
                        child: Text(
                          e.value,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: e.key == level ? AppColors.accent : null,
                          ),
                        ),
                      ),
                      Text(
                        '${e.key == level ? percent : _percents[e.key]}%',
                        style: t.textTheme.labelSmall?.copyWith(
                          color: e.key == level ? AppColors.accent : t.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
