import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

/// Reproduce el timelapse de una impresión.
class TimelapseScreen extends StatefulWidget {
  final String url;
  final String title;
  const TimelapseScreen({super.key, required this.url, required this.title});

  @override
  State<TimelapseScreen> createState() => _TimelapseScreenState();
}

class _TimelapseScreenState extends State<TimelapseScreen> {
  late final VideoPlayerController _c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
  String? _error;

  @override
  void initState() {
    super.initState();
    _c
        .initialize()
        .then((_) {
          if (!mounted) return;
          _c.setLooping(true);
          _c.play();
          setState(() {});
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = 'No se pudo reproducir el video');
        });
    _c.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Descargar / compartir',
            icon: const Icon(Icons.download_rounded),
            onPressed: () => launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication),
          ),
        ],
      ),
      body: Center(
        child: _error != null
            ? Text(_error!, style: const TextStyle(color: Colors.white70))
            : !_c.value.isInitialized
            ? const CircularProgressIndicator()
            : GestureDetector(
                onTap: () => _c.value.isPlaying ? _c.pause() : _c.play(),
                child: AspectRatio(
                  aspectRatio: _c.value.aspectRatio,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      VideoPlayer(_c),
                      if (!_c.value.isPlaying)
                        const CircleAvatar(
                          radius: 32,
                          backgroundColor: Colors.black54,
                          child: Icon(Icons.play_arrow_rounded, size: 40, color: Colors.white),
                        ),
                      Positioned(left: 0, right: 0, bottom: 0, child: VideoProgressIndicator(_c, allowScrubbing: true)),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
