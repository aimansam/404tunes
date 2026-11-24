import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../player/cache_manager.dart';
import 'now_playing.dart';
import 'playlists_page.dart';
import 'queue_page.dart';
import 'search_page.dart';
import 'settings_page.dart';

/// Navigation rail + mini player on wide screens (desktop), bottom bar on phones.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.app, required this.cache});
  final AppState app;
  final CacheManager cache;
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;

  // Lets the page stack move between the wide (rail) and narrow (bottom bar) layouts without losing
  // its state, e.g. search results when a tablet rotates or a desktop window is resized.
  final _pagesKey = GlobalKey();

  static const _dest = [
    (Icons.search, 'Search'),
    (Icons.queue_music, 'Playlists'),
    (Icons.format_list_numbered, 'Queue'),
    (Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final pages = [
      SearchPage(app: app),
      PlaylistsPage(key: ValueKey('pl-${app.me!.id}'), app: app),
      QueuePage(app: app),
      SettingsPage(app: app, cache: widget.cache),
    ];
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final body = IndexedStack(key: _pagesKey, index: _index, children: pages);

    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.space): _PlayerIntent(_PlayerKey.toggle),
        SingleActivator(LogicalKeyboardKey.arrowRight, control: true): _PlayerIntent(_PlayerKey.next),
        SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): _PlayerIntent(_PlayerKey.previous),
      },
      child: Actions(
        actions: {
          _PlayerIntent: _PlayerAction(app),
        },
        child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(children: [
              Expanded(
                child: wide
                    ? Row(children: [
                        NavigationRail(
                          selectedIndex: _index,
                          labelType: NavigationRailLabelType.all,
                          onDestinationSelected: (i) => setState(() => _index = i),
                          destinations: [
                            for (final d in _dest)
                              NavigationRailDestination(icon: Icon(d.$1), label: Text(d.$2)),
                          ],
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(child: body),
                      ])
                    : body,
              ),
              MiniPlayer(app: app),
            ]),
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  destinations: [
                    for (final d in _dest) NavigationDestination(icon: Icon(d.$1), label: d.$2),
                  ],
                ),
        ),
      ),
      ),
    );
  }
}

enum _PlayerKey { toggle, next, previous }

class _PlayerIntent extends Intent {
  const _PlayerIntent(this.key);
  final _PlayerKey key;
}

/// Keyboard shortcuts for the player. Disabled while a text field has focus, so typing a space
/// in the search box types a space instead of pausing the music.
class _PlayerAction extends Action<_PlayerIntent> {
  _PlayerAction(this.app);
  final AppState app;

  @override
  bool isEnabled(_PlayerIntent intent) {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx == null || ctx.findAncestorWidgetOfExactType<EditableText>() == null;
  }

  @override
  Object? invoke(_PlayerIntent intent) {
    switch (intent.key) {
      case _PlayerKey.toggle:
        app.player.togglePlay();
      case _PlayerKey.next:
        app.player.next();
      case _PlayerKey.previous:
        app.player.previous();
    }
    return null;
  }
}
