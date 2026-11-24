import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/playlists_repo.dart';
import 'widgets.dart';

class PlaylistsPage extends StatefulWidget {
  const PlaylistsPage({super.key, required this.app});
  final AppState app;
  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  late Future<List<PlaylistInfo>> _future = _load();

  Future<List<PlaylistInfo>> _load() => widget.app.playlists.list(widget.app.me!.id);
  void _reload() {
    if (mounted) setState(() => _future = _load());
  }

  @override
  void initState() {
    super.initState();
    // Playlists can change from other screens (search menu, now playing): stay up to date.
    widget.app.playlists.revision.addListener(_reload);
  }

  @override
  void dispose() {
    widget.app.playlists.revision.removeListener(_reload);
    super.dispose();
  }

  Future<void> _create() async {
    final name = await askText(context, title: 'New playlist', label: 'Name', ok: 'Create');
    if (name == null || name.trim().isEmpty) return;
    await widget.app.playlists.create(widget.app.me!.id, name);
    _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(
            onPressed: _create, icon: const Icon(Icons.add), label: const Text('New playlist')),
        body: FutureBuilder<List<PlaylistInfo>>(
          future: _future,
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final lists = snap.data!;
            if (lists.isEmpty) {
              return const Center(child: Text('No playlists yet.\nCreate one, then add songs from search.', textAlign: TextAlign.center));
            }
            return ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: lists.length,
              itemBuilder: (_, i) {
                final l = lists[i];
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.queue_music)),
                  title: Text(l.name),
                  subtitle: Text('${l.count} ${l.count == 1 ? 'song' : 'songs'}'),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => PlaylistDetailPage(app: widget.app, info: l)));
                    _reload();
                  },
                );
              },
            );
          },
        ),
      );
}

class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({super.key, required this.app, required this.info});
  final AppState app;
  final PlaylistInfo info;
  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  List<PlaylistItem>? _items;
  late String _name = widget.info.name;

  int get _me => widget.app.me!.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await widget.app.playlists.items(_me, widget.info.id);
    if (mounted) setState(() => _items = items);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: Text(_name),
        actions: [
          IconButton(
            tooltip: 'Rename',
            icon: const Icon(Icons.edit),
            onPressed: () async {
              final n = await askText(context, title: 'Rename playlist', label: 'Name', initial: _name);
              if (n == null || n.trim().isEmpty) return;
              await app.playlists.rename(_me, widget.info.id, n);
              setState(() => _name = n.trim());
            },
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (!await confirm(context, 'Delete "$_name"?', 'The songs themselves are not affected.')) return;
              await app.playlists.delete(_me, widget.info.id);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? const Center(child: Text('Empty. Add songs from search with the "…" menu.'))
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(spacing: 8, children: [
                      FilledButton.icon(
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Play'),
                        onPressed: () => app.player.playTracks(items.map((e) => e.track).toList()),
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.shuffle),
                        label: const Text('Shuffle'),
                        onPressed: () {
                          app.player.setShuffle(true);
                          app.player.playTracks(items.map((e) => e.track).toList());
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.queue),
                        label: const Text('Add to queue'),
                        onPressed: () async {
                          await app.player.addAllToQueue(items.map((e) => e.track).toList());
                          if (context.mounted) showSnack(context, 'Added to queue');
                        },
                      ),
                    ]),
                  ),
                  Expanded(
                    child: ReorderableListView.builder(
                      buildDefaultDragHandles: true,
                      itemCount: items.length,
                      onReorderItem: (from, to) async {
                        final list = List.of(items);
                        list.insert(to, list.removeAt(from));
                        setState(() => _items = list);
                        await app.playlists.reorder(_me, widget.info.id, list.map((e) => e.itemId).toList());
                      },
                      itemBuilder: (_, i) {
                        final it = items[i];
                        return Dismissible(
                          key: ValueKey(it.itemId),
                          direction: DismissDirection.endToStart,
                          background: Container(
                              color: Theme.of(context).colorScheme.errorContainer,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 24),
                              child: const Icon(Icons.delete)),
                          onDismissed: (_) async {
                            await app.playlists.removeItem(_me, widget.info.id, it.itemId);
                            _load();
                          },
                          child: TrackTile(
                            app: app,
                            track: it.track,
                            showMenu: false,
                            onTap: () => app.player.playTracks(items.map((e) => e.track).toList(), start: i),
                            trailing: const SizedBox(width: 40),
                          ),
                        );
                      },
                    ),
                  ),
                ]),
    );
  }
}
