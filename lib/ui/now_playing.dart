import 'package:flutter/material.dart';

import '../app_state.dart';
import '../player/queue_model.dart';
import 'widgets.dart';

/// Seek bar with elapsed / total time.
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.app});
  final AppState app;
  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _drag; // seconds while the user is dragging

  @override
  Widget build(BuildContext context) {
    final p = widget.app.player.player;
    final fallback = widget.app.player.current?.duration;
    return StreamBuilder<Duration>(
      stream: p.positionStream,
      builder: (context, snap) {
        final pos = snap.data ?? Duration.zero;
        final total = p.duration ?? (fallback == null ? null : Duration(seconds: fallback));
        final max = (total?.inMilliseconds ?? 0) / 1000.0;
        final value = (_drag ?? pos.inMilliseconds / 1000.0).clamp(0.0, max > 0 ? max : 1.0);
        return Row(children: [
          SizedBox(width: 56, child: Text(fmtDuration(value), maxLines: 1, softWrap: false, textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
          Expanded(
            child: Slider(
              value: value,
              max: max > 0 ? max : 1.0,
              onChanged: max > 0 ? (v) => setState(() => _drag = v) : null,
              onChangeEnd: (v) {
                widget.app.player.seek(Duration(milliseconds: (v * 1000).round()));
                setState(() => _drag = null);
              },
            ),
          ),
          SizedBox(width: 56, child: Text(fmtDuration(max), maxLines: 1, softWrap: false, style: const TextStyle(fontSize: 12))),
        ]);
      },
    );
  }
}

class TransportControls extends StatelessWidget {
  const TransportControls({super.key, required this.app, this.big = true});
  final AppState app;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final c = app.player;
    final q = c.queue;
    final scheme = Theme.of(context).colorScheme;
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      IconButton(
        tooltip: 'Shuffle',
        icon: Icon(Icons.shuffle, color: q.shuffle ? scheme.primary : null),
        onPressed: () => c.setShuffle(!q.shuffle),
      ),
      IconButton(iconSize: big ? 36 : 28, icon: const Icon(Icons.skip_previous), onPressed: c.previous),
      c.loading
          ? SizedBox(
              width: big ? 72 : 56,
              height: big ? 72 : 56,
              child: const Padding(padding: EdgeInsets.all(18), child: CircularProgressIndicator(strokeWidth: 3)))
          : IconButton.filled(
              iconSize: big ? 44 : 32,
              icon: Icon(c.playing ? Icons.pause : Icons.play_arrow),
              onPressed: c.togglePlay,
            ),
      IconButton(iconSize: big ? 36 : 28, icon: const Icon(Icons.skip_next), onPressed: c.next),
      IconButton(
        tooltip: 'Repeat',
        icon: Icon(q.repeat == Repeat.one ? Icons.repeat_one : Icons.repeat,
            color: q.repeat == Repeat.off ? null : scheme.primary),
        onPressed: c.cycleRepeat,
      ),
    ]);
  }
}

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app.player,
        builder: (context, _) {
          final c = app.player;
          final t = c.current;
          return Scaffold(
            appBar: AppBar(
              leading: IconButton(icon: const Icon(Icons.keyboard_arrow_down), onPressed: () => Navigator.of(context).pop()),
              title: const Text('Now playing'),
              actions: [
                if (t != null)
                  IconButton(
                    tooltip: 'Add to playlist',
                    icon: const Icon(Icons.playlist_add),
                    onPressed: () => addToPlaylistDialog(context, app, [t]),
                  ),
              ],
            ),
            body: t == null
                ? const Center(child: Text('Nothing playing'))
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Flexible(
                            child: LayoutBuilder(builder: (_, box) {
                              final size = box.biggest.shortestSide.clamp(120.0, 360.0);
                              return Artwork(t.id, size: size, radius: 16);
                            }),
                          ),
                          const SizedBox(height: 24),
                          Text(t.title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 4),
                          Text(t.channel, style: Theme.of(context).textTheme.bodyMedium),
                          if (c.error != null) ...[
                            const SizedBox(height: 8),
                            Text(c.error!, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                          ],
                          const SizedBox(height: 16),
                          SeekBar(app: app),
                          TransportControls(app: app),
                          const SizedBox(height: 8),
                          Row(children: [
                            const Icon(Icons.volume_down),
                            Expanded(child: Slider(value: c.volume, onChanged: c.setVolume)),
                            const Icon(Icons.volume_up),
                          ]),
                        ]),
                      ),
                    ),
                  ),
          );
        },
      );
}

/// The always-visible bar above the navigation; tap to open the full player.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app.player,
        builder: (context, _) {
          final c = app.player;
          final t = c.current;
          if (t == null) return const SizedBox.shrink();
          final scheme = Theme.of(context).colorScheme;
          return Material(
            color: scheme.surfaceContainerHigh,
            child: InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  fullscreenDialog: true, builder: (_) => NowPlayingPage(app: app))),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                StreamBuilder<Duration>(
                  stream: c.player.positionStream,
                  builder: (_, snap) {
                    final total = c.player.duration ?? Duration(seconds: t.duration ?? 0);
                    final v = total.inMilliseconds == 0
                        ? 0.0
                        : ((snap.data ?? Duration.zero).inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
                    return LinearProgressIndicator(value: v, minHeight: 2);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(children: [
                    Artwork(t.id, size: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text(c.error ?? t.channel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: c.error != null ? scheme.error : null)),
                      ]),
                    ),
                    IconButton(icon: const Icon(Icons.skip_previous), onPressed: c.previous),
                    c.loading
                        ? const SizedBox(width: 48, height: 48, child: Padding(padding: EdgeInsets.all(13), child: CircularProgressIndicator(strokeWidth: 2.5)))
                        : IconButton(icon: Icon(c.playing ? Icons.pause : Icons.play_arrow), onPressed: c.togglePlay),
                    IconButton(icon: const Icon(Icons.skip_next), onPressed: c.next),
                  ]),
                ),
              ]),
            ),
          );
        },
      );
}
