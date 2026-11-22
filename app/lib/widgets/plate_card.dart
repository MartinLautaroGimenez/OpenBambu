import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// URL de la imagen de una placa: la foto de MakerWorld (por el proxy del servidor)
/// o la miniatura guardada en el propio .3mf.
String? plateImageUrl(BuildContext context, ProjectPlate p, {String? libraryId, int width = 400}) {
  final api = context.read<AppState>().api;
  if (api == null) return null;
  if (p.image != null) return api.catalogImage(p.image!, width: width);
  if (p.thumbnail && libraryId != null) return api.thumbnail(libraryId, p.index).toString();
  return null;
}

/// Muestra una imagen a pantalla completa con zoom.
void showImageViewer(BuildContext context, String url, {String? title}) {
  showDialog(
    context: context,
    builder: (c) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 5,
              child: Center(child: Image.network(url, fit: BoxFit.contain)),
            ),
          ),
          SafeArea(
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(c),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
                if (title != null)
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Tarjeta de una placa: imagen, nombre, tiempo, peso y colores.
class PlateCard extends StatelessWidget {
  final ProjectPlate plate;
  final String? libraryId;
  final bool selected;
  final VoidCallback? onTap;
  final double width;
  const PlateCard({
    super.key,
    required this.plate,
    this.libraryId,
    this.selected = false,
    this.onTap,
    this.width = 140,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final url = plateImageUrl(context, plate, libraryId: libraryId);
    final big = plateImageUrl(context, plate, libraryId: libraryId, width: 1200);
    final details = [
      if (plate.predictionS != null) formatDuration((plate.predictionS! / 60).round()),
      if (plate.weightG != null) '${plate.weightG!.round()} g',
      if (plate.predictionS == null && plate.objects > 0) '${plate.objects} ${plate.objects == 1 ? 'pieza' : 'piezas'}',
    ];
    return SizedBox(
      width: width,
      child: Material(
        color: selected ? AppColors.accent.withValues(alpha: 0.12) : t.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap ?? (big == null ? null : () => showImageViewer(context, big, title: plate.label)),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? AppColors.accent : Colors.transparent, width: 2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(color: t.colorScheme.surfaceContainerHigh),
                      if (url != null)
                        Image.network(
                          url,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Icon(Icons.view_in_ar_rounded, color: t.colorScheme.outline),
                        )
                      else
                        Icon(Icons.view_in_ar_rounded, color: t.colorScheme.outline, size: 36),
                      if (big != null && onTap != null)
                        Positioned(
                          right: 4,
                          top: 4,
                          child: Material(
                            color: Colors.black45,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => showImageViewer(context, big, title: plate.label),
                              child: const Padding(
                                padding: EdgeInsets.all(5),
                                child: Icon(Icons.zoom_in_rounded, size: 18, color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      if (selected)
                        const Positioned(
                          left: 6,
                          top: 6,
                          child: CircleAvatar(
                            radius: 12,
                            backgroundColor: AppColors.accent,
                            child: Icon(Icons.check_rounded, size: 16, color: Colors.black),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        plate.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (details.isNotEmpty)
                        Text(
                          details.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                        ),
                      if (plate.filaments.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            children: [
                              for (final f in plate.filaments.take(6))
                                Padding(
                                  padding: const EdgeInsets.only(right: 3),
                                  child: Tooltip(
                                    message: '${f.type}${f.usedG != null ? ' · ${f.usedG!.round()} g' : ''}',
                                    child: CircleAvatar(radius: 6, backgroundColor: parseHex(f.color) ?? Colors.grey),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
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
