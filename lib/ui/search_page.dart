import 'package:flutter/material.dart';

import '../app_state.dart';
import '../yt/models.dart';
import 'widgets.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.app});
  final AppState app;
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _c = TextEditingController();
  bool _playlists = false;
  Future<List<Object>>? _future;
  String _query = '';

  void _run() {
    final q = _c.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _query = q;
      _future = _playlists
          ? widget.app.yt.searchPlaylists(q).then((l) => l.cast<Object>())
          : widget.app.yt.search(q).then((l) => l.cast<Object>());
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(children: [
          TextField(
            controller: _c,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _run(),
            decoration: InputDecoration(
              hintText: 'Search songs or playlists',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _run),
              border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(28))),
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Songs'), icon: Icon(Icons.music_note)),
              ButtonSegment(value: true, label: Text('Playlists'), icon: Icon(Icons.queue_music)),
            ],
            selected: {_playlists},
            onSelectionChanged: (s) {
              setState(() => _playlists = s.first);
              if (_query.isNotEmpty) _run();
            },
          ),
        ]),
      ),
      Expanded(
        child: _future == null
            ? const Center(child: Text('Search for something to listen to'))
            : FutureBuilder<List<Object>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return ErrorNote('${snap.error}'.replaceFirst('YtException: ', ''), onRetry: _run);
                  }
                  final items = snap.data!;
                  if (items.isEmpty) return const Center(child: Text('Nothing found'));
                  if (_playlists) {
                    return ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final r = items[i] as PlaylistResult;
                        return ListTile(
                          leading: Artwork(r.thumbVideoId),
                          title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(r.channel, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => OnlinePlaylistPage(app: app, result: r))),
                        );
                      },
                    );
                  }
                  final tracks = items.cast<Track>();
                  return ListenableBuilder(
                    listenable: app.player,
                    builder: (_, __) => ListView.builder(
                      itemCount: tracks.length,
                      itemBuilder: (_, i) => TrackTile(
                        app: app,
                        track: tracks[i],
                        selected: app.player.current?.id == tracks[i].id,
                        // Keep going through the results after the song you picked.
                        onTap: () => app.player.playTracks(tracks, start: i),
                      ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}

/// The songs of a YouTube playlist found by search.
class OnlinePlaylistPage extends StatelessWidget {
  const OnlinePlaylistPage({super.key, required this.app, required this.result});
  final AppState app;
  final PlaylistResult result;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(result.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: FutureBuilder<PlaylistContents>(
          future: app.yt.playlist(result.listId),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) return ErrorNote('${snap.error}'.replaceFirst('YtException: ', ''));
            final items = snap.data!.items;
            return Column(children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(spacing: 8, children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: Text('Play all (${items.length})'),
                    onPressed: items.isEmpty
                        ? null
                        : () {
                            app.player.playTracks(items);
                            Navigator.of(context).maybePop();
                          },
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.queue),
                    label: const Text('Add to queue'),
                    onPressed: items.isEmpty
                        ? null
                        : () async {
                            await app.player.addAllToQueue(items);
                            if (context.mounted) showSnack(context, 'Added ${items.length} songs');
                          },
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.library_add),
                    label: const Text('Save as playlist'),
                    onPressed: items.isEmpty
                        ? null
                        : () async {
                            final me = app.me!;
                            final name = await askText(context,
                                title: 'Save as playlist', label: 'Name', initial: snap.data!.title);
                            if (name == null || name.trim().isEmpty) return;
                            final id = await app.playlists.create(me.id, name);
                            await app.playlists.addTracks(me.id, id, items);
                            if (context.mounted) showSnack(context, 'Saved ${items.length} songs');
                          },
                  ),
                ]),
              ),
              Expanded(
                child: ListenableBuilder(
                  listenable: app.player,
                  builder: (_, __) => ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (_, i) => TrackTile(
                      app: app,
                      track: items[i],
                      selected: app.player.current?.id == items[i].id,
                      onTap: () => app.player.playTracks(items, start: i),
                    ),
                  ),
                ),
              ),
            ]);
          },
        ),
      );
}
