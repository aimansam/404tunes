import 'package:flutter/material.dart';

import 'app_state.dart';
import 'player/cache_manager.dart';
import 'ui/auth_pages.dart';
import 'ui/shell.dart';

class TunesApp extends StatelessWidget {
  const TunesApp({super.key, required this.app, required this.cache});
  final AppState app;
  final CacheManager cache;

  ThemeData _theme(Brightness b) => ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF7C4DFF),
        brightness: b,
      );

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '404tunes',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: ListenableBuilder(
          listenable: app,
          builder: (context, _) => switch (app.stage) {
            Stage.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
            Stage.setupAdmin => SetupAdminPage(app: app),
            Stage.pickProfile => ProfilePickerPage(app: app),
            Stage.ready => Shell(app: app, cache: cache),
          },
        ),
      );
}
