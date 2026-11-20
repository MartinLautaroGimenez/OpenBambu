import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/makerworld_login.dart';
import '../print_screen.dart';
import '../slice_screen.dart';
import 'catalog_screen.dart';

String htmlToText(String html) {
  var s = html
      .replaceAll(RegExp(r'<\s*br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</\s*(p|div|h\d|li)\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '• ')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  const entities = {'&nbsp;': ' ', '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'"};
  entities.forEach((k, v) => s = s.replaceAll(k, v));
  return s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

class CatalogDetailScreen extends StatefulWidget {
  final String source;
  final String id;
  final CatalogItem? preview;
  const CatalogDetailScreen({super.key, required this.source, required this.id, this.preview});

  @override
  State<CatalogDetailScreen> createState() => _CatalogDetailScreenState();
}

class _CatalogDetailScreenState extends State<CatalogDetailScreen> {
  CatalogDetail? _d;
  String? _error;
  final Set<String> _selected = {};
  bool _downloading = false;
  bool _showFullText = false;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      final d = await api.catalogDetail(widget.source, widget.id);
      if (!mounted) return;
      final model = context.read<AppState>().selected?.modelLabel;
      setState(() {
        _d = d;
        // Preseleccionar: perfil para mi impresora (MakerWorld) o el único archivo
        final mine = d.files.where((f) => f.printer != null && f.printer == model).firstOrNull;
        if (mine != null) {
          _selected.add(mine.id);
        } else if (d.files.length == 1) {
          _selected.add(d.files.first.id);
        }
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _download() async {
    final s = context.read<AppState>();
    final api = s.api, printer = s.selected;
    if (api == null || _selected.isEmpty) return;
    setState(() => _downloading = true);
    try {
      final items = await api.catalogDownload(widget.source, widget.id, _selected.toList());
      if (!mounted) return;
      if (items.length == 1 && printer != null) {
        final it = items.first;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                it.sliced ? PrintScreen(printerId: printer.id, item: it) : SliceScreen(printerId: printer.id, item: it),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${items.length} archivos agregados a la biblioteca (pestaña Biblioteca)')),
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.danger));
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = _d;
    final preview = widget.preview;
    final images = d?.images.isNotEmpty == true ? d!.images : [if (preview?.image != null) preview!.image!];
    final title = d?.item.title ?? preview?.title ?? '';
    final model = context.watch<AppState>().selected?.modelLabel;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 340,
            pinned: true,
            actions: [
              if ((d?.item.url ?? preview?.url) != null)
                IconButton(
                  tooltip: 'Abrir en el navegador',
                  icon: const Icon(Icons.open_in_new_rounded),
                  onPressed: () =>
                      launchUrl(Uri.parse(d?.item.url ?? preview!.url!), mode: LaunchMode.externalApplication),
                ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: t.colorScheme.surfaceContainer),
                  if (images.isNotEmpty)
                    PageView.builder(
                      itemCount: images.length,
                      onPageChanged: (i) => setState(() => _page = i),
                      itemBuilder: (_, i) {
                        final api = context.read<AppState>().api;
                        final img = Image.network(
                          api?.catalogImage(images[i], width: 1000) ?? images[i],
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(Icons.view_in_ar_rounded, size: 64),
                        );
                        return i == 0 ? Hero(tag: 'cat-${widget.source}-${widget.id}', child: img) : img;
                      },
                    ),
                  if (images.length > 1)
                    Positioned(
                      bottom: 12,
                      left: 0,
                      right: 0,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < images.length && i < 12; i++)
                            Container(
                              width: i == _page ? 18 : 7,
                              height: 7,
                              margin: const EdgeInsets.symmetric(horizontal: 2.5),
                              decoration: BoxDecoration(
                                color: i == _page ? Colors.white : Colors.white54,
                                borderRadius: BorderRadius.circular(99),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
            sliver: SliverList.list(
              children: [
                Text(title, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    CircleAvatar(backgroundColor: sourceColors[widget.source] ?? Colors.grey, radius: 5),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        [d?.item.author ?? preview?.author, d?.license].whereType<String>().join(' · '),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Stat(
                      icon: Icons.favorite_rounded,
                      label: 'Me gusta',
                      value: compactCount(d?.item.likes ?? preview?.likes ?? 0),
                    ),
                    Stat(
                      icon: Icons.download_rounded,
                      label: 'Descargas',
                      value: compactCount(d?.item.downloads ?? preview?.downloads ?? 0),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Text(_error!, style: const TextStyle(color: AppColors.danger)),
                  )
                else if (d == null)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  if (d.note != null)
                    Container(
                      margin: const EdgeInsets.only(top: 16),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.info.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded, color: AppColors.info),
                          const SizedBox(width: 10),
                          Expanded(child: Text(d.note!)),
                          if (widget.source == 'makerworld')
                            TextButton(
                              onPressed: () async {
                                if (await showMakerWorldLogin(context)) {
                                  setState(() => _d = null);
                                  _load();
                                }
                              },
                              child: const Text('Vincular'),
                            ),
                        ],
                      ),
                    ),
                  SectionTitle(d.files.any((f) => f.kind == 'profile') ? 'Perfiles de impresión' : 'Archivos'),
                  if (d.files.isEmpty) const Text('Este modelo no tiene archivos descargables compatibles.'),
                  for (final f in d.files)
                    _FileTile(
                      file: f,
                      mine: f.printer == model,
                      selected: _selected.contains(f.id),
                      onChanged: (v) => setState(() => v ? _selected.add(f.id) : _selected.remove(f.id)),
                    ),
                  if (d.description.isNotEmpty) ...[
                    const SectionTitle('Descripción'),
                    Text(
                      htmlToText(d.description),
                      maxLines: _showFullText ? null : 8,
                      overflow: _showFullText ? null : TextOverflow.fade,
                    ),
                    TextButton(
                      onPressed: () => setState(() => _showFullText = !_showFullText),
                      child: Text(_showFullText ? 'Ver menos' : 'Ver más'),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: d == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _downloading || _selected.isEmpty || !d.downloadable ? null : _download,
                  icon: _downloading
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.download_rounded),
                  label: Text(
                    _downloading
                        ? 'Descargando al servidor…'
                        : _selected.length > 1
                        ? 'Descargar ${_selected.length} archivos'
                        : 'Descargar y preparar',
                  ),
                ),
              ),
            ),
    );
  }
}

class _FileTile extends StatelessWidget {
  final CatalogFile file;
  final bool mine;
  final bool selected;
  final ValueChanged<bool> onChanged;
  const _FileTile({required this.file, required this.mine, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final details = <String>[
      if (file.printer != null) file.printer!,
      if (file.predictionS != null) formatDuration((file.predictionS! / 60).round()),
      if (file.weightG != null) '${file.weightG!.round()} g',
      if (file.size != null) '${(file.size! / 1024 / 1024).toStringAsFixed(1)} MB',
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: CheckboxListTile(
        value: selected,
        onChanged: (v) => onChanged(v ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          file.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (details.isNotEmpty) Text(details.join(' · ')),
            if (file.filaments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    for (final f in file.filaments.take(8))
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Tooltip(
                          message: f.type,
                          child: CircleAvatar(radius: 7, backgroundColor: parseHex(f.color) ?? Colors.grey),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
        secondary: mine
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Tu ${file.printer}',
                  style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w800, fontSize: 12),
                ),
              )
            : Text(file.kind == 'profile' ? 'PERFIL' : file.kind.toUpperCase(), style: t.textTheme.labelSmall),
      ),
    );
  }
}
