import 'package:flutter/material.dart';

import '../app_state.dart';
import '../update/update_controller.dart';

/// The strip above the mini player while a newer version is waiting.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.updates});
  final UpdateController updates;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: updates,
        builder: (context, _) {
          if (!updates.showBanner) return const SizedBox.shrink();
          final colors = Theme.of(context).colorScheme;
          return Material(
            color: colors.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(children: [
                Expanded(
                  child: Text('404 Tunes ${updates.release!.version} is available',
                      style: TextStyle(color: colors.onSecondaryContainer)),
                ),
                TextButton(onPressed: updates.dismiss, child: const Text('Later')),
                FilledButton(onPressed: () => showUpdateDialog(context, updates), child: const Text('Update')),
              ]),
            ),
          );
        },
      );
}

/// Release notes, then download progress and install.
Future<void> showUpdateDialog(BuildContext context, UpdateController updates) => showDialog<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: updates,
        builder: (context, _) {
          final r = updates.release;
          final phase = updates.phase;
          if (r == null) {
            return AlertDialog(
              title: const Text('404 Tunes is up to date'),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
            );
          }
          final downloading = phase == UpdatePhase.downloading;
          final installing = phase == UpdatePhase.installing;
          final platform = Theme.of(context).platform;
          final hint = !updates.canInstall
              ? 'Download the new version from the release page and replace this one.'
              : updates.needsPermission
                  ? 'Allow 404 Tunes to install apps, then come back and press Install.'
                  : platform == TargetPlatform.android
                      ? 'Android will ask you to confirm the update.'
                      : 'The app closes, installs the update and opens again.';
          return AlertDialog(
            title: Text('Version ${r.version} is available'),
            content: SizedBox(
              width: 420,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (r.notes.isNotEmpty) ...[
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: SingleChildScrollView(child: Text(r.notes, style: const TextStyle(fontSize: 12))),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(hint),
                if (downloading || installing) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(value: downloading ? updates.progress : null),
                  const SizedBox(height: 6),
                  Text(downloading ? 'Downloading ${(updates.progress * 100).floor()}%' : 'Starting the installer…',
                      style: const TextStyle(fontSize: 12)),
                ],
                if (updates.error != null) ...[
                  const SizedBox(height: 12),
                  Text(updates.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ]),
            ),
            actions: [
              if (downloading)
                TextButton(onPressed: updates.cancel, child: const Text('Cancel'))
              else
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
              if (!downloading && !installing)
                FilledButton(
                  onPressed: updates.update,
                  child: Text(!updates.canInstall
                      ? 'Open download page'
                      : phase == UpdatePhase.ready
                          ? 'Install'
                          : 'Update now'),
                ),
            ],
          );
        },
      ),
    );

/// The "Updates" rows in Settings.
class UpdateSettings extends StatelessWidget {
  const UpdateSettings({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final updates = app.updates!;
    return ListenableBuilder(
      listenable: Listenable.merge([updates, app.settings]),
      builder: (context, _) {
        if (!updates.enabled) {
          return const ListTile(title: Text('404 Tunes (development build)'), subtitle: Text('Update checks are off in builds not made from a release.'));
        }
        final found = updates.release;
        final status = found != null
            ? 'Version ${found.version} is available'
            : switch (updates.phase) {
                UpdatePhase.checking => 'Checking…',
                UpdatePhase.upToDate => 'Up to date',
                UpdatePhase.failed => updates.error ?? 'Could not check',
                _ => 'Not checked yet',
              };
        return Column(children: [
          ListTile(
            title: Text('404 Tunes ${updates.updater.currentVersion}'),
            subtitle: Text(status),
            trailing: found != null
                ? FilledButton(onPressed: () => showUpdateDialog(context, updates), child: const Text('Update'))
                : OutlinedButton(
                    onPressed: updates.phase == UpdatePhase.checking ? null : updates.check, child: const Text('Check for updates')),
          ),
          SwitchListTile(
            title: const Text('Check for updates automatically'),
            subtitle: const Text('Asks GitHub for the latest version at launch and once a day'),
            value: app.settings.autoUpdateCheck,
            onChanged: (v) async {
              await app.settings.setAutoUpdateCheck(v);
              if (v) updates.check();
            },
          ),
        ]);
      },
    );
  }
}
