import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class _Obj {
  final int id;
  final String name;
  final Rect? bbox;
  final bool skipped;
  final Path shape;
  _Obj(this.id, this.name, this.bbox, this.skipped, this.shape);
}

/// Omitir objetos de la impresión en curso: la cama vista desde arriba.
class SkipObjectsScreen extends StatefulWidget {
  final String printerId;
  const SkipObjectsScreen({super.key, required this.printerId});

  @override
  State<SkipObjectsScreen> createState() => _SkipObjectsScreenState();
}

class _SkipObjectsScreenState extends State<SkipObjectsScreen> {
  List<_Obj>? _objs;
  Size _bed = const Size(256, 256);
  String? _error;
  final Set<int> _selected = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final info = await _get(api, '/printers/${widget.printerId}/objects');
      final shapes = <int, Path>{};
      try {
        final prev = await _get(api, '/library/${info['library_id']}/plates/${info['plate']}/preview');
        final layers = prev['layers'] as List;
        // Silueta: primera capa + una capa del medio, solo paredes
        for (final l in {layers.first, layers[layers.length ~/ 2]}) {
          for (final p in (l as Map)['paths'] as List) {
            final o = p['o'];
            if (o == null || !(p['t'] == 'ow' || p['t'] == 'iw' || p['t'] == 'bs')) continue;
            final pts = (p['p'] as List).cast<num>();
            final path = shapes.putIfAbsent((o as num).toInt(), Path.new);
            path.moveTo(pts[0] / 10, pts[1] / 10);
            for (var i = 2; i + 1 < pts.length; i += 2) {
              path.lineTo(pts[i] / 10, pts[i + 1] / 10);
            }
          }
        }
      } catch (_) {}
      final bed = (info['bed'] as List).cast<num>();
      setState(() {
        _bed = Size(bed[0].toDouble(), bed[1].toDouble());
        _objs = [
          for (final o in info['objects'] as List)
            _Obj(
              (o['id'] as num).toInt(),
              o['name'] ?? 'Objeto',
              o['bbox'] == null
                  ? null
                  : Rect.fromLTRB(
                      (o['bbox'][0] as num).toDouble(),
                      (o['bbox'][1] as num).toDouble(),
                      (o['bbox'][2] as num).toDouble(),
                      (o['bbox'][3] as num).toDouble(),
                    ),
              o['skipped'] == true,
              shapes[(o['id'] as num).toInt()] ?? Path(),
            ),
        ];
        _selected.removeWhere((id) => _objs!.any((o) => o.id == id && o.skipped));
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<Map<String, dynamic>> _get(ApiClient api, String path) async {
    final res = await http.get(api.uri(path), headers: api.headers);
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) throw ApiException(body['detail'] ?? 'Error ${res.statusCode}', res.statusCode);
    return body as Map<String, dynamic>;
  }

  void _toggle(_Obj o) {
    if (o.skipped) return;
    setState(() => _selected.contains(o.id) ? _selected.remove(o.id) : _selected.add(o.id));
  }

  Future<void> _skip() async {
    final names = _objs!.where((o) => _selected.contains(o.id)).map((o) => o.name).join(', ');
    if (!await confirm(
      context,
      title: 'Omitir ${_selected.length} objeto(s)',
      message: '$names\n\nLa impresora deja de imprimirlos desde la capa actual. No se puede deshacer.',
      ok: 'Omitir',
      danger: true,
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    final ok = await act(
      context,
      (api, id) => api.post(widget.printerId, '/objects/skip', {'ids': _selected.toList()}),
      success: 'Objetos omitidos',
    );
    if (ok) {
      _selected.clear();
      await _load();
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final objs = _objs;
    return Scaffold(
      appBar: AppBar(title: const Text('Omitir objetos')),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : objs == null
          ? const Center(child: CircularProgressIndicator())
          : objs.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Este archivo no tiene objetos identificables.\nLaminalo con la opción "Excluir objetos" activada.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              children: [
                Text(
                  'Tocá los objetos que querés dejar de imprimir (por ejemplo, uno que se despegó).',
                  style: TextStyle(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                AspectRatio(
                  aspectRatio: _bed.width / _bed.height,
                  child: LayoutBuilder(
                    builder: (ctx, box) {
                      final scale = box.maxWidth / _bed.width;
                      return GestureDetector(
                        onTapUp: (d) {
                          // pantalla → cama (Y invertida: el origen de la cama está abajo)
                          final x = d.localPosition.dx / scale, y = _bed.height - d.localPosition.dy / scale;
                          _Obj? hit;
                          double best = double.infinity;
                          for (final o in objs) {
                            final b = o.bbox;
                            if (b == null || !b.inflate(3).contains(Offset(x, y))) continue;
                            final area = b.width * b.height;
                            if (area < best) {
                              best = area;
                              hit = o;
                            }
                          }
                          if (hit != null) _toggle(hit);
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: CustomPaint(
                            painter: _BedPainter(objs, _selected, _bed, t.colorScheme.surfaceContainer),
                            size: Size(box.maxWidth, box.maxWidth * _bed.height / _bed.width),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SectionTitle('Objetos'),
                Card(
                  child: Column(
                    children: [
                      for (final (i, o) in objs.indexed)
                        CheckboxListTile(
                          value: o.skipped || _selected.contains(o.id),
                          onChanged: o.skipped ? null : (_) => _toggle(o),
                          secondary: CircleAvatar(
                            radius: 14,
                            backgroundColor: o.skipped
                                ? t.colorScheme.surfaceContainerHighest
                                : (_selected.contains(o.id) ? AppColors.danger : AppColors.accent).withValues(
                                    alpha: 0.2,
                                  ),
                            child: Text('${i + 1}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                          ),
                          title: Text(
                            o.name,
                            style: TextStyle(decoration: o.skipped ? TextDecoration.lineThrough : null),
                          ),
                          subtitle: o.skipped ? const Text('Omitido') : null,
                        ),
                    ],
                  ),
                ),
              ],
            ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
                  onPressed: _busy ? null : _skip,
                  icon: const Icon(Icons.block_rounded),
                  label: Text('Omitir ${_selected.length} objeto(s)'),
                ),
              ),
            ),
    );
  }
}

class _BedPainter extends CustomPainter {
  final List<_Obj> objs;
  final Set<int> selected;
  final Size bed;
  final Color bg;
  _BedPainter(this.objs, this.selected, this.bed, this.bg);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / bed.width;
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    // grilla cada 32 mm
    final grid = Paint()
      ..color = Colors.white10
      ..strokeWidth = 1;
    for (double v = 0; v <= bed.width; v += 32) {
      canvas.drawLine(Offset(v * s, 0), Offset(v * s, size.height), grid);
    }
    for (double v = 0; v <= bed.height; v += 32) {
      canvas.drawLine(Offset(0, size.height - v * s), Offset(size.width, size.height - v * s), grid);
    }
    canvas.save();
    canvas.translate(0, size.height);
    canvas.scale(s, -s);
    for (final (i, o) in objs.indexed) {
      final color = o.skipped
          ? Colors.grey
          : selected.contains(o.id)
          ? AppColors.danger
          : AppColors.accent;
      if (o.bbox != null) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(o.bbox!.inflate(1.5), const Radius.circular(2)),
          Paint()..color = color.withValues(alpha: o.skipped ? 0.12 : 0.2),
        );
      }
      canvas.drawPath(
        o.shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = color,
      );
      if (o.bbox != null) {
        final c = o.bbox!.center;
        canvas.save();
        canvas.translate(c.dx, c.dy);
        canvas.scale(1 / s, -1 / s);
        if (o.skipped || selected.contains(o.id)) {
          final x = Paint()
            ..color = color
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round;
          canvas.drawLine(const Offset(-8, -8), const Offset(8, 8), x);
          canvas.drawLine(const Offset(8, -8), const Offset(-8, 8), x);
        } else {
          final tp = TextPainter(
            text: TextSpan(
              text: '${i + 1}',
              style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 16),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
        }
        canvas.restore();
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BedPainter old) => true;
}
