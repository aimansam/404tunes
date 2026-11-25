import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/profiles_repo.dart';

class _Centered extends StatelessWidget {
  const _Centered({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: child),
            ),
          ),
        ),
      );
}

/// First launch: create the admin account. There are no default credentials.
class SetupAdminPage extends StatefulWidget {
  const SetupAdminPage({super.key, required this.app});
  final AppState app;
  @override
  State<SetupAdminPage> createState() => _SetupAdminPageState();
}

class _SetupAdminPageState extends State<SetupAdminPage> {
  final _name = TextEditingController();
  final _secret = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    if (_secret.text != _confirm.text) {
      setState(() => _error = "The PINs / passwords don't match");
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.createAdmin(_name.text, _secret.text);
    } on ProfileException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Centered(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Image.asset('assets/branding/logo.png', height: 96),
          const SizedBox(height: 12),
          Text('Welcome to 404 Tunes', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'Create the admin account. The admin can add other profiles on this device, each with its own playlists.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Admin name', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
              controller: _secret,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'PIN or password (4+ characters)', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
              controller: _confirm,
              obscureText: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'Repeat PIN or password', border: OutlineInputBorder())),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Create admin'),
          ),
        ]),
      );
}

/// Who is listening? Pick a profile, then enter its PIN / password.
class ProfilePickerPage extends StatelessWidget {
  const ProfilePickerPage({super.key, required this.app});
  final AppState app;

  // The dialog signs in by itself when the PIN is right.
  Future<void> _signIn(BuildContext context, Profile p) => showDialog<void>(
        context: context,
        builder: (_) => _PinDialog(app: app, profile: p),
      );

  @override
  Widget build(BuildContext context) => _Centered(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text("Who's listening?", style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 24),
          Wrap(spacing: 16, runSpacing: 16, alignment: WrapAlignment.center, children: [
            for (final p in app.allProfiles)
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _signIn(context, p),
                child: SizedBox(
                  width: 110,
                  child: Column(children: [
                    CircleAvatar(
                      radius: 36,
                      child: Text(p.name.characters.first.toUpperCase(), style: const TextStyle(fontSize: 28)),
                    ),
                    const SizedBox(height: 8),
                    Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (p.isAdmin) const Text('admin', style: TextStyle(fontSize: 11)),
                  ]),
                ),
              ),
          ]),
        ]),
      );
}

class _PinDialog extends StatefulWidget {
  const _PinDialog({required this.app, required this.profile});
  final AppState app;
  final Profile profile;
  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _c = TextEditingController();
  final _focus = FocusNode();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.app.login(widget.profile, _c.text);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = 'Wrong PIN or password';
        _c.clear();
      });
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.profile.name),
        content: TextField(
          controller: _c,
          focusNode: _focus,
          autofocus: true,
          obscureText: true,
          onSubmitted: (_) => _go(),
          decoration: InputDecoration(labelText: 'PIN or password', errorText: _error),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _busy ? null : _go, child: const Text('Sign in')),
        ],
      );
}
