import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import '../settings.dart';
import '../data/profiles_repo.dart';
import '../player/cache_manager.dart';
import '../presence/presence_service.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.app, required this.cache});
  final AppState app;
  final CacheManager cache;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _version;
  bool _updating = false;
  int? _cacheBytes;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.yt.version().then((v) => mounted ? setState(() => _version = v) : null,
        onError: (_) => mounted ? setState(() => _version = 'unavailable') : null);
    _refreshCache();
  }

  Future<void> _refreshCache() async {
    final b = await widget.cache.sizeBytes();
    if (mounted) setState(() => _cacheBytes = b);
  }

  Future<void> _update() async {
    setState(() => _updating = true);
    try {
      final v = await app.yt.update();
      if (mounted) {
        setState(() => _version = v);
        showSnack(context, 'yt-dlp is now $v');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Update failed: ${'$e'.replaceFirst('YtException: ', '')}');
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _pickCookies() async {
    final picked = await FilePicker.pickFiles(dialogTitle: 'Choose cookies.txt');
    final src = picked.isEmpty ? null : picked.first.path;
    if (src == null) return;
    // Keep our own copy: on Android the picked file is a temporary one.
    final dir = await getApplicationSupportDirectory();
    final copy = await File(src).copy(p.join(dir.path, 'cookies.txt'));
    await app.settings.setCookiesPath(copy.path);
    app.yt.cookiesPath = copy.path;
    if (mounted) setState(() {});
  }

  Future<void> _editDiscordId() async {
    final s = app.settings;
    final c = TextEditingController(text: s.hasCustomDiscordClientId ? s.discordClientId : '');
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discord application ID'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
            'Create an application at discord.com/developers/applications and copy its Application ID. '
            'The application\'s name is what Discord shows: "Listening to 404 Tunes".',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: c,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: AppSettings.builtInDiscordClientId.isEmpty ? 'Application ID' : 'Leave empty to use the built-in one',
            ),
            onSubmitted: (_) => Navigator.pop(ctx, c.text),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (v != null) await s.setDiscordClientId(v);
  }

  List<Widget> _discordTiles(BuildContext context) {
    final s = app.settings;
    final presence = app.presence!;
    final hasId = s.discordClientId.isNotEmpty;
    return [
      const Divider(),
      const _Section('Discord'),
      SwitchListTile(
        title: const Text('Show what I\'m playing on Discord'),
        subtitle: Text(hasId
            ? 'Shows "Listening to 404 Tunes" with the song while it plays. Needs the Discord desktop app open.'
            : 'Add a Discord application ID first.'),
        value: s.discordEnabled && hasId,
        onChanged: hasId ? s.setDiscordEnabled : null,
      ),
      ValueListenableBuilder<PresenceStatus>(
        valueListenable: presence.status,
        builder: (context, st, _) => ListTile(
          title: const Text('Discord application ID'),
          subtitle: Text([
            if (!hasId)
              'Not set'
            else if (s.hasCustomDiscordClientId)
              s.discordClientId
            else
              'Built in',
            if (s.discordEnabled && hasId)
              switch (st) {
                PresenceStatus.showing => 'Showing on Discord',
                PresenceStatus.unavailable => 'Discord not reachable: is the desktop app open?',
                _ => 'Ready',
              },
          ].join('  ·  ')),
          trailing: OutlinedButton(onPressed: _editDiscordId, child: Text(hasId ? 'Change' : 'Set')),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = app.settings;
    final me = app.me!;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => ListView(children: [
        ListTile(
          leading: CircleAvatar(child: Text(me.name.characters.first.toUpperCase())),
          title: Text(me.name),
          subtitle: Text(me.isAdmin ? 'Admin' : 'Profile'),
          trailing: OutlinedButton(onPressed: app.logout, child: const Text('Switch profile')),
        ),
        if (me.isAdmin)
          ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('Manage profiles'),
            subtitle: const Text('Add, rename, reset PIN, delete'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AdminPage(app: app))),
          ),
        const Divider(),
        const _Section('Offline cache'),
        SwitchListTile(
          title: const Text('Save played songs on this device'),
          subtitle: const Text('Cached songs replay without internet'),
          value: s.cacheEnabled,
          onChanged: s.setCacheEnabled,
        ),
        ListTile(
          title: const Text('Cache size limit'),
          subtitle: Text('${s.cacheMaxMb} MB  ·  using ${_cacheBytes == null ? '…' : '${(_cacheBytes! / 1048576).toStringAsFixed(0)} MB'}'),
          trailing: DropdownButton<int>(
            value: const [256, 512, 1024, 2048, 5120, 10240].contains(s.cacheMaxMb) ? s.cacheMaxMb : 2048,
            items: const [256, 512, 1024, 2048, 5120, 10240]
                .map((v) => DropdownMenuItem(value: v, child: Text(v >= 1024 ? '${v ~/ 1024} GB' : '$v MB')))
                .toList(),
            onChanged: (v) async {
              if (v == null) return;
              await s.setCacheMaxMb(v);
              await widget.cache.trim(s.cacheMaxBytes);
              _refreshCache();
            },
          ),
        ),
        ListTile(
          title: const Text('Clear cache'),
          trailing: const Icon(Icons.delete_outline),
          onTap: () async {
            await widget.cache.clear();
            _refreshCache();
          },
        ),
        if (app.presence != null) ..._discordTiles(context),
        const Divider(),
        const _Section('YouTube'),
        ListTile(
          title: const Text('yt-dlp'),
          subtitle: Text(_version ?? 'checking…'),
          trailing: _updating
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : OutlinedButton(onPressed: _update, child: const Text('Update')),
        ),
        ListTile(
          title: const Text('Cookies file'),
          subtitle: Text(s.cookiesPath ?? 'Not set. Only needed if YouTube says "confirm you\'re not a bot".'),
          trailing: s.cookiesPath == null
              ? OutlinedButton(onPressed: _pickCookies, child: const Text('Choose'))
              : IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () async {
                    await s.setCookiesPath(null);
                    app.yt.cookiesPath = null;
                  }),
        ),
        const Divider(),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Playing YouTube audio outside YouTube\'s own player goes against YouTube\'s terms. Use at your own risk. '
            'Profiles keep playlists apart on this device; they are a lock, not encryption.',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

/// Admin only: add, rename, reset and delete profiles.
class AdminPage extends StatefulWidget {
  const AdminPage({super.key, required this.app});
  final AppState app;
  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  AppState get app => widget.app;

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on ProfileException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    final name = await askText(context, title: 'New profile', label: 'Name', ok: 'Next');
    if (name == null || name.trim().isEmpty || !mounted) return;
    final pin = await askText(context, title: 'PIN or password for $name', label: '4+ characters', obscure: true, ok: 'Create');
    if (pin == null || !mounted) return;
    await _guard(() => app.addProfile(name, pin));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Profiles')),
        floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.person_add), label: const Text('Add profile')),
        body: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
          for (final p in app.allProfiles)
            ListTile(
              leading: CircleAvatar(child: Text(p.name.characters.first.toUpperCase())),
              title: Text(p.name),
              subtitle: Text(p.isAdmin ? 'Admin' : 'Profile'),
              trailing: PopupMenuButton<String>(
                onSelected: (a) async {
                  if (a == 'rename') {
                    final n = await askText(context, title: 'Rename', label: 'Name', initial: p.name);
                    if (n != null) await _guard(() => app.renameProfile(p, n));
                  } else if (a == 'reset') {
                    final pin = await askText(context, title: 'New PIN for ${p.name}', label: '4+ characters', obscure: true, ok: 'Save');
                    if (pin != null) {
                      await _guard(() => app.resetSecret(p, pin));
                      if (context.mounted) showSnack(context, 'PIN changed');
                    }
                  } else if (a == 'delete') {
                    if (!context.mounted) return;
                    if (await confirm(context, 'Delete ${p.name}?', 'Their playlists and saved queue are removed too.')) {
                      await _guard(() => app.deleteProfile(p));
                    }
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  const PopupMenuItem(value: 'reset', child: Text('Reset PIN / password')),
                  if (p.id != app.me!.id) const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ),
        ]),
      );
}
