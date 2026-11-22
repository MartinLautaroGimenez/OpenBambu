import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import 'catalog_detail_screen.dart';

const sourceColors = {
  'makerworld': Color(0xFF00AE42),
  'printables': Color(0xFFFA6831),
  'thingiverse': Color(0xFF248BFB),
};

String compactCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
  return '$n';
}

/// Pantalla principal: modelos populares y buscador de todas las fuentes.
class CatalogScreen extends StatefulWidget {
  final VoidCallback onOpenPrinter;
  const CatalogScreen({super.key, required this.onOpenPrinter});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> with AutomaticKeepAliveClientMixin {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  List<CatalogSource> _sources = [];
  String? _source;
  String _query = '';
  final List<CatalogItem> _items = [];
  int _page = 0;
  bool _loading = false;
  bool _end = false;
  String? _error;
  Timer? _debounce;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) _more();
    });
    _init();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final api = context.read<AppState>().api;
    if (api == null) return;
    try {
      _sources = (await api.catalogSources()).where((s) => s.enabled).toList();
    } catch (_) {}
    _reload();
  }

  void _reload() {
    _items.clear();
    _page = 0;
    _end = false;
    _error = null;
    _more();
  }

  Future<void> _more() async {
    final api = context.read<AppState>().api;
    if (api == null || _loading || _end) return;
    setState(() => _loading = true);
    final query = _query, source = _source;
    try {
      final items = await api.catalogBrowse(query: query, source: source, page: _page);
      if (!mounted || query != _query || source != _source) return;
      final seen = _items.map((e) => '${e.source}/${e.id}').toSet();
      setState(() {
        _items.addAll(items.where((e) => seen.add('${e.source}/${e.id}')));
        _page++;
        _end = items.isEmpty;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (v.trim() == _query) return;
      setState(() => _query = v.trim());
      _reload();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final columns = width > 900 ? 4 : (width > 600 ? 3 : 2);

    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('Explorar', style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                        const Spacer(),
                        _PrinterPill(onTap: widget.onOpenPrinter),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SearchBar(
                      controller: _search,
                      hintText: 'Buscar modelos…',
                      leading: const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.search_rounded)),
                      trailing: [
                        if (_search.text.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () {
                              _search.clear();
                              _onSearch('');
                            },
                          ),
                      ],
                      elevation: const WidgetStatePropertyAll(0),
                      backgroundColor: WidgetStatePropertyAll(t.colorScheme.surfaceContainer),
                      onChanged: (v) {
                        setState(() {});
                        _onSearch(v);
                      },
                      onSubmitted: (v) {
                        _debounce?.cancel();
                        setState(() => _query = v.trim());
                        _reload();
                      },
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [_chip('Todo', null), for (final s in _sources) _chip(s.label, s.id)]),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _query.isEmpty ? 'Populares' : 'Resultados para «$_query»',
                      style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
          ),
          if (_items.isEmpty && _loading)
            const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
          else if (_items.isEmpty && _error != null)
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_rounded, size: 40),
                      const SizedBox(height: 8),
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      OutlinedButton(onPressed: _reload, child: const Text('Reintentar')),
                    ],
                  ),
                ),
              ),
            )
          else if (_items.isEmpty && !_loading)
            const SliverFillRemaining(child: Center(child: Text('No se encontraron modelos')))
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.72,
                ),
                itemCount: _items.length,
                itemBuilder: (_, i) => _ModelCard(item: _items[i]),
              ),
            ),
          if (_items.isNotEmpty && _loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(String label, String? id) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: _source == id,
      avatar: id == null ? null : CircleAvatar(backgroundColor: sourceColors[id] ?? Colors.grey, radius: 5),
      onSelected: (_) {
        setState(() => _source = id);
        _reload();
      },
    ),
  );
}

class _ModelCard extends StatelessWidget {
  final CatalogItem item;
  const _ModelCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CatalogDetailScreen(source: item.source, id: item.id, preview: item),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: t.colorScheme.surfaceContainer),
                  if (item.image != null)
                    Hero(
                      tag: 'cat-${item.source}-${item.id}',
                      child: Image.network(
                        context.read<AppState>().api?.catalogImage(item.image!) ?? item.image!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(Icons.view_in_ar_rounded, size: 40),
                      ),
                    )
                  else
                    const Icon(Icons.view_in_ar_rounded, size: 40),
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: (sourceColors[item.source] ?? Colors.grey).withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(switch (item.source) {
                        'makerworld' => 'MakerWorld',
                        'printables' => 'Printables',
                        'thingiverse' => 'Thingiverse',
                        _ => item.source,
                      }, style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, height: 1.2),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.author ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                        ),
                      ),
                      Icon(Icons.favorite_rounded, size: 12, color: t.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 2),
                      Text(compactCount(item.likes), style: t.textTheme.labelSmall),
                      const SizedBox(width: 6),
                      Icon(Icons.download_rounded, size: 12, color: t.colorScheme.onSurfaceVariant),
                      Text(compactCount(item.downloads), style: t.textTheme.labelSmall),
                    ],
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

/// Estado resumido de la impresora en la portada.
class _PrinterPill extends StatelessWidget {
  final VoidCallback onTap;
  const _PrinterPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.watch<AppState>().selected;
    if (p == null) return const SizedBox.shrink();
    final s = p.status;
    final c = stateColor(s.state);
    return InkWell(
      borderRadius: BorderRadius.circular(99),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(99)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (s.isActive)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  value: s.state == 'PREPARE' ? null : s.job.progress / 100,
                  strokeWidth: 2.5,
                  color: c,
                  backgroundColor: c.withValues(alpha: 0.25),
                ),
              )
            else
              Icon(Icons.print_rounded, size: 16, color: c),
            const SizedBox(width: 7),
            Text(
              s.isActive ? '${s.job.progress}% · ${formatDuration(s.job.remainingMin)}' : s.stateLabel,
              style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
