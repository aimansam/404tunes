import 'package:flutter/foundation.dart';

import 'data/playlists_repo.dart';
import 'data/profiles_repo.dart';
import 'player/player_controller.dart';
import 'settings.dart';
import 'yt/yt_service.dart';

enum Stage { loading, setupAdmin, pickProfile, ready }

/// Everything the UI needs, wired together once in main(). Tracks who is signed in.
class AppState extends ChangeNotifier {
  AppState({
    required this.profiles,
    required this.playlists,
    required this.player,
    required this.settings,
    required this.yt,
  });

  final ProfilesRepo profiles;
  final PlaylistsRepo playlists;
  final PlayerController player;
  final AppSettings settings;
  final YtService yt;

  Stage stage = Stage.loading;
  Profile? me;
  List<Profile> allProfiles = const [];

  Future<void> start() async {
    yt.cookiesPath = settings.cookiesPath;
    await _refresh();
  }

  Future<void> _refresh() async {
    allProfiles = await profiles.list();
    if (allProfiles.isEmpty) {
      stage = Stage.setupAdmin;
    } else if (me == null) {
      stage = Stage.pickProfile;
    } else {
      stage = Stage.ready;
    }
    notifyListeners();
  }

  Future<void> createAdmin(String name, String secret) async {
    final p = await profiles.createFirstAdmin(name, secret);
    await _signIn(p);
  }

  /// Returns false when the PIN / password is wrong.
  Future<bool> login(Profile p, String secret) async {
    if (!await profiles.verify(p.id, secret)) return false;
    await _signIn(p);
    return true;
  }

  Future<void> _signIn(Profile p) async {
    me = p;
    await settings.setLastProfileId(p.id);
    await player.attachProfile(p.id);
    await _refresh();
  }

  Future<void> logout() async {
    me = null;
    await player.attachProfile(null);
    await _refresh();
  }

  // ---- admin ----
  Future<void> addProfile(String name, String secret) async {
    await profiles.create(name, secret);
    await _refresh();
  }

  Future<void> deleteProfile(Profile p) async {
    await profiles.delete(p.id, actingAdminId: me!.id);
    await _refresh();
  }

  Future<void> resetSecret(Profile p, String secret) =>
      profiles.setSecret(p.id, secret);

  Future<void> renameProfile(Profile p, String name) async {
    await profiles.rename(p.id, name);
    if (me?.id == p.id) me = await profiles.byId(p.id);
    await _refresh();
  }
}
