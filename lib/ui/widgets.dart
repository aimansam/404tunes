import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../yt/models.dart';

String fmtDuration(num? seconds) {
  if (seconds == null) return '';
  final s = seconds.round();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

void showSnack(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
}

class Artwork extends StatelessWidget {
  const Artwork(this.videoId, {super.key, this.size = 48, this.radius = 6});
  final String? videoId;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, size: size * 0.5),
    );
    if (videoId == null) return ClipRRect(borderRadius: BorderRadius.circular(radius), child: placeholder);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: 'https://i.ytimg.com/vi/$videoId/mqdefault.jpg',
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => placeholder,
        errorWidget: (_, __, ___) => placeholder,
      ),
    );
  }
}

enum TrackAction { playNext, addToQueue, addToPlaylist }

/// One song row with a "..." menu (play next, add to queue, add to playlist).
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.app,
    required this.track,
    this.onTap,
    this.selected = false,
    this.trailing,
    this.showMenu = true,
  });

  final AppState app;
  final Track track;
  final VoidCallback? onTap;
  final bool selected;
  final Widget? trailing;
  final bool showMenu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Artwork(track.id),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: selected ? TextStyle(color: scheme.primary, fontWeight: FontWeight.w600) : null),
      subtitle: Text(
          [track.channel, fmtDuration(track.duration)].where((s) => s.isNotEmpty).join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      onTap: onTap,
      trailing: trailing ??
          (showMenu
              ? PopupMenuButton<TrackAction>(
                  tooltip: 'More',
                  onSelected: (a) => _run(context, a),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: TrackAction.playNext, child: Text('Play next')),
                    PopupMenuItem(value: TrackAction.addToQueue, child: Text('Add to queue')),
                    PopupMenuItem(value: TrackAction.addToPlaylist, child: Text('Add to playlist…')),
                  ],
                )
              : null),
    );
  }

  Future<void> _run(BuildContext context, TrackAction a) async {
    switch (a) {
      case TrackAction.playNext:
        app.player.playNext(track);
        showSnack(context, 'Playing next');
      case TrackAction.addToQueue:
        await app.player.addToQueue(track);
        if (context.mounted) showSnack(context, 'Added to queue');
      case TrackAction.addToPlaylist:
        await addToPlaylistDialog(context, app, [track]);
    }
  }
}

/// Pick one of my playlists (or make a new one) and add [tracks] to it.
Future<void> addToPlaylistDialog(BuildContext context, AppState app, List<Track> tracks) async {
  final me = app.me!;
  final lists = await app.playlists.list(me.id);
  if (!context.mounted) return;
  final choice = await showDialog<int>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(tracks.length == 1 ? 'Add to playlist' : 'Add ${tracks.length} songs to…'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, -1),
          child: const Row(children: [Icon(Icons.add), SizedBox(width: 12), Text('New playlist…')]),
        ),
        for (final l in lists)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, l.id),
            child: Text('${l.name}  (${l.count})'),
          ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  var id = choice;
  if (id == -1) {
    final name = await askText(context, title: 'New playlist', label: 'Name');
    if (name == null || name.trim().isEmpty) return;
    id = await app.playlists.create(me.id, name);
  }
  await app.playlists.addTracks(me.id, id, tracks);
  if (context.mounted) showSnack(context, 'Added to playlist');
}

Future<String?> askText(BuildContext context,
    {required String title, required String label, String initial = '', bool obscure = false, String ok = 'OK'}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        obscureText: obscure,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(ok)),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String body, {String ok = 'Delete'}) async =>
    (await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
        ],
      ),
    )) ??
    false;

class ErrorNote extends StatelessWidget {
  const ErrorNote(this.message, {super.key, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error, size: 36),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ]),
        ),
      );
}
