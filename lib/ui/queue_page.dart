import 'package:flutter/material.dart';

import '../app_state.dart';
import 'widgets.dart';

class QueuePage extends StatelessWidget {
  const QueuePage({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app.player,
        builder: (context, _) {
          final q = app.player.queue;
          final items = q.items;
          if (items.isEmpty) {
            return const Center(child: Text('The queue is empty.\nPlay a song or add one with the "…" menu.', textAlign: TextAlign.center));
          }
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(children: [
                Text('${items.length} in queue', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton(onPressed: app.player.clearUpcoming, child: const Text('Clear upcoming')),
                TextButton(onPressed: app.player.clearQueue, child: const Text('Clear all')),
              ]),
            ),
            Expanded(
              child: ReorderableListView.builder(
                itemCount: items.length,
                onReorderItem: (from, to) {
                  app.player.move(from, to);
                },
                itemBuilder: (_, i) {
                  final it = items[i];
                  final isCurrent = i == q.position;
                  return Dismissible(
                    key: ValueKey(it.uid),
                    direction: DismissDirection.endToStart,
                    background: Container(
                        color: Theme.of(context).colorScheme.errorContainer,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        child: const Icon(Icons.delete)),
                    onDismissed: (_) => app.player.removeAt(i),
                    child: TrackTile(
                      app: app,
                      track: it.track,
                      selected: isCurrent,
                      showMenu: false,
                      onTap: () => app.player.jumpTo(i),
                      trailing: SizedBox(
                        width: 56,
                        child: isCurrent
                            ? Icon(app.player.playing ? Icons.volume_up : Icons.pause,
                                color: Theme.of(context).colorScheme.primary)
                            : null,
                      ),
                    ),
                  );
                },
              ),
            ),
          ]);
        },
      );
}
