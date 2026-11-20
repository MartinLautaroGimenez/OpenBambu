import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../theme.dart';

const featureInfo = {
  'ow': ('Pared exterior', Color(0xFFFF8A3D)),
  'iw': ('Pared interior', Color(0xFFFFD166)),
  'si': ('Relleno', Color(0xFFB0413E)),
  'ss': ('Relleno sólido', Color(0xFF9B5DE5)),
  'ts': ('Superficie superior', Color(0xFFF15BB5)),
  'bs': ('Superficie inferior', Color(0xFF4EA8DE)),
  'br': ('Puente', Color(0xFF00BBF9)),
  'gi': ('Relleno de huecos', Color(0xFF2EC4B6)),
  'sp': ('Soporte', Color(0xFF7BD389)),
  'sk': ('Brim / falda', Color(0xFF9E9E9E)),
  'pt': ('Torre de purga', Color(0xFF8D99AE)),
  'ir': ('Planchado', Color(0xFF6C757D)),
  'ot': ('Otro', Color(0xFF6C757D)),
};

class _Layer {
  final double z;
  final Map<(String, int), Path> paths;
  _Layer(this.z, this.paths);
}

/// Vista previa del G-code laminado: capa por capa (2D) o pieza completa (3D).
class GcodePreviewScreen extends StatefulWidget {
  final LibraryItem item;
  final Plate plate;
  const GcodePreviewScreen({super.key, required this.item, required this.plate});

  @override
  State<GcodePreviewScreen> createState() => _GcodePreviewScreenState();
}

class _GcodePreviewScreenState extends State<GcodePreviewScreen> {
  List<_Layer>? _layers;
  Rect _bbox = Rect.zero;
  String? _error;
  int _layer = 0;
  bool _threeD = true;
  bool _byFilament = false;
  bool _showInfill = true;
  double _angle = -math.pi / 4;
  double _tilt = 0.6;
  double _zoom = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final res = await http.get(
        api.uri('/library/${widget.item.id}/plates/${widget.plate.index}/preview'),
        headers: api.headers,
      );
      if (res.statusCode != 200) {
        String msg = 'No se pudo generar la vista previa';
        try {
          msg = jsonDecode(res.body)['detail'];
        } catch (_) {}
        throw Exception(msg);
      }
      final d = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final layers = <_Layer>[];
      for (final l in d['layers'] as List) {
        final paths = <(String, int), Path>{};
        for (final p in l['paths'] as List) {
          final pts = (p['p'] as List).cast<num>();
          final path = paths.putIfAbsent((p['t'] as String, (p['f'] as num).toInt()), Path.new);
          path.moveTo(pts[0] / 10, pts[1] / 10);
          for (var i = 2; i + 1 < pts.length; i += 2) {
            path.lineTo(pts[i] / 10, pts[i + 1] / 10);
          }
        }
        layers.add(_Layer((l['z'] as num).toDouble(), paths));
      }
      final b = (d['bbox'] as List).cast<num>();
      setState(() {
        _layers = layers;
        _bbox = Rect.fromLTRB(b[0].toDouble(), b[1].toDouble(), b[2].toDouble(), b[3].toDouble());
        _layer = layers.length - 1;
      });
    } catch (e) {
      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final layers = _layers;
    final colors = [for (final f in widget.plate.filaments) parseHex(f.color) ?? Colors.white];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vista previa'),
        actions: [
          IconButton(
            tooltip: _byFilament ? 'Color por tipo de línea' : 'Color por filamento',
            icon: Icon(_byFilament ? Icons.category_rounded : Icons.palette_rounded),
            onPressed: () => setState(() => _byFilament = !_byFilament),
          ),
          IconButton(
            tooltip: _showInfill ? 'Ocultar relleno' : 'Mostrar relleno',
            icon: Icon(_showInfill ? Icons.grid_on_rounded : Icons.grid_off_rounded),
            onPressed: () => setState(() => _showInfill = !_showInfill),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : layers == null
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Leyendo el G-code…')],
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: GestureDetector(
                    onScaleUpdate: (d) => setState(() {
                      if (_threeD) {
                        _angle += d.focalPointDelta.dx * 0.01;
                        _tilt = (_tilt - d.focalPointDelta.dy * 0.005).clamp(0.15, 1.45);
                      }
                      if (d.scale != 1) _zoom = (_zoom * (1 + (d.scale - 1) * 0.08)).clamp(0.5, 6);
                    }),
                    child: Container(
                      color: const Color(0xFF0B0C0E),
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _GcodePainter(
                          layers: layers,
                          upTo: _layer,
                          bbox: _bbox,
                          threeD: _threeD,
                          angle: _angle,
                          tilt: _tilt,
                          zoom: _zoom,
                          byFilament: _byFilament,
                          filamentColors: colors,
                          showInfill: _showInfill,
                        ),
                      ),
                    ),
                  ),
                ),
                Container(
                  color: t.colorScheme.surfaceContainerLow,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      children: [
                        Row(
                          children: [
                            SegmentedButton<bool>(
                              showSelectedIcon: false,
                              segments: const [
                                ButtonSegment(value: true, label: Text('3D')),
                                ButtonSegment(value: false, label: Text('Capa')),
                              ],
                              selected: {_threeD},
                              onSelectionChanged: (v) => setState(() => _threeD = v.first),
                            ),
                            const Spacer(),
                            Text(
                              'Capa ${_layer + 1}/${layers.length} · Z ${layers[_layer].z.toStringAsFixed(2)} mm',
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                        Slider(
                          value: _layer.toDouble(),
                          max: (layers.length - 1).toDouble().clamp(0, double.infinity),
                          divisions: layers.length > 1 ? layers.length - 1 : null,
                          onChanged: (v) => setState(() => _layer = v.round()),
                        ),
                        SizedBox(
                          height: 30,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              if (_byFilament)
                                for (final (i, f) in widget.plate.filaments.indexed)
                                  _Legend(color: colors[i], label: '${f.type} (${i + 1})')
                              else
                                for (final key in _usedFeatures(layers))
                                  _Legend(color: featureInfo[key]!.$2, label: featureInfo[key]!.$1),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  List<String> _usedFeatures(List<_Layer> layers) {
    final used = <String>{};
    for (final l in layers) {
      for (final k in l.paths.keys) {
        used.add(featureInfo.containsKey(k.$1) ? k.$1 : 'ot');
      }
    }
    return featureInfo.keys.where(used.contains).toList();
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  const _Legend({required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 12),
    child: Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    ),
  );
}

class _GcodePainter extends CustomPainter {
  final List<_Layer> layers;
  final int upTo;
  final Rect bbox;
  final bool threeD;
  final double angle, tilt, zoom;
  final bool byFilament;
  final List<Color> filamentColors;
  final bool showInfill;

  _GcodePainter({
    required this.layers,
    required this.upTo,
    required this.bbox,
    required this.threeD,
    required this.angle,
    required this.tilt,
    required this.zoom,
    required this.byFilament,
    required this.filamentColors,
    required this.showInfill,
  });

  Color _color(String type, int f) {
    if (byFilament) return f < filamentColors.length ? filamentColors[f] : Colors.white;
    return (featureInfo[type] ?? featureInfo['ot']!).$2;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (layers.isEmpty || bbox.isEmpty) return;
    final c = bbox.center;
    final maxZ = layers.last.z;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (!threeD) {
      // Vista superior de la capa elegida, con la anterior en tenue
      final scale = math.min(size.width / bbox.width, size.height / bbox.height) * 0.88 * zoom;
      canvas.translate(size.width / 2, size.height / 2);
      canvas.scale(scale, -scale);
      canvas.translate(-c.dx, -c.dy);
      paint.strokeWidth = 0.42;
      if (upTo > 0) {
        for (final e in layers[upTo - 1].paths.entries) {
          canvas.drawPath(e.value, paint..color = _color(e.key.$1, e.key.$2).withValues(alpha: 0.12));
        }
      }
      for (final e in layers[upTo].paths.entries) {
        if (!showInfill && (e.key.$1 == 'si' || e.key.$1 == 'ss')) continue;
        canvas.drawPath(e.value, paint..color = _color(e.key.$1, e.key.$2));
      }
      return;
    }

    // 3D: cada capa es una transformación afín de su plano XY (rotación + inclinación + altura)
    final cosA = math.cos(angle), sinA = math.sin(angle);
    final sinT = math.sin(tilt), cosT = math.cos(tilt);
    final radius = math.sqrt(bbox.width * bbox.width + bbox.height * bbox.height) / 2;
    final projH = radius * 2 * sinT + maxZ * cosT;
    final scale = math.min(size.width / (radius * 2.1), size.height / (projH * 1.1 + 1)) * zoom;
    final cy = size.height / 2 + (maxZ * cosT * scale) / 2;
    paint.strokeWidth = 0.5;

    for (var i = 0; i <= upTo; i++) {
      final l = layers[i];
      final top = i == upTo;
      // pantalla = M · (x - cx, y - cy) + (w/2, cy - z·cosT·scale)
      final a = cosA * scale, b = -sinA * scale;
      final d = -sinA * sinT * scale, e = -cosA * sinT * scale;
      final tx = size.width / 2 - (a * c.dx + b * c.dy);
      final ty = cy - l.z * cosT * scale - (d * c.dx + e * c.dy);
      canvas.save();
      canvas.transform(Matrix4(a, d, 0, 0, b, e, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1).storage);
      final shade = 0.45 + 0.55 * (l.z / (maxZ == 0 ? 1 : maxZ));
      for (final entry in l.paths.entries) {
        final type = entry.key.$1;
        if (!showInfill && !top && (type == 'si' || type == 'ss')) continue;
        final base = _color(type, entry.key.$2);
        paint.color = top ? base : Color.lerp(Colors.black, base, shade)!;
        canvas.drawPath(entry.value, paint);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_GcodePainter old) =>
      old.upTo != upTo ||
      old.threeD != threeD ||
      old.angle != angle ||
      old.tilt != tilt ||
      old.zoom != zoom ||
      old.byFilament != byFilament ||
      old.showInfill != showInfill ||
      old.layers != layers;
}
