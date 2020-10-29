import 'dart:async';
import 'dart:io';

import 'package:dart_git/git.dart';
import 'package:dynamic_theme/dynamic_theme.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization_loader/easy_localization_loader.dart';
import 'package:flutter/material.dart';
import 'package:notium/app_router.dart';
import 'package:notium/app_settings.dart';
import 'package:notium/appstate.dart';
import 'package:notium/event_logger.dart';
import 'package:notium/settings.dart';
import 'package:notium/state_container.dart';
import 'package:notium/themes.dart';
import 'package:notium/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

class JournalApp extends StatefulWidget {
  final AppState appState;

  static Future main() async {
    await Log.init();

    var appState = AppState();
    var settings = Settings.instance;
    var appSettings = AppSettings.instance;
    Log.i("AppSetting ${appSettings.toMap()}");
    Log.i("Setting ${settings.toLoggableMap()}");

    var dir = await getApplicationDocumentsDirectory();
    appState.gitBaseDirectory = dir.path;

    var gitRepoDir = p.join(appState.gitBaseDirectory, settings.folderName);

    var repoDirStat = File(gitRepoDir).statSync();
    if (repoDirStat.type != FileSystemEntityType.directory) {
      settings.folderName = "notium_notes";
      var repoPath = p.join(
        appState.gitBaseDirectory,
        settings.folderName,
      );
      Log.i("Calling GitInit at: $repoPath");
      await GitRepository.init(repoPath);

      settings.save();
    } else {
      var gitRepo = await GitRepository.load(gitRepoDir);
      var remotes = gitRepo.config.remotes;
      appState.remoteGitRepoConfigured = remotes.isNotEmpty;
    }
    appState.cacheDir = (await getApplicationSupportDirectory()).path;

    Widget app = ChangeNotifierProvider.value(
      value: settings,
      child: ChangeNotifierProvider(
        create: (_) {
          return StateContainer(appState: appState, settings: settings);
        },
        child: ChangeNotifierProvider(
          child: JournalApp(appState),
          create: (_) {
            assert(appState.notesFolder != null);
            return appState.notesFolder;
          },
        ),
      ),
    );

    app = ChangeNotifierProvider.value(
      value: appSettings,
      child: app,
    );

    runApp(EasyLocalization(
      child: app,
      supportedLocales: [
        const Locale('en', 'US'),
      ], // Remember to update Info.plist
      path: 'assets/langs',
      useOnlyLangCode: true,
      assetLoader: YamlAssetLoader(),
    ));
  }

  static bool isInDebugMode = false;

  JournalApp(this.appState);

  @override
  _JournalAppState createState() => _JournalAppState();
}

class _JournalAppState extends State<JournalApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  String _pendingShortcut;

  StreamSubscription _intentDataStreamSubscription;
  String _sharedText;
  List<String> _sharedImages;

  @override
  void initState() {
    super.initState();
    _initShareSubscriptions();
  }

  void _afterBuild(BuildContext context) {
    if (_pendingShortcut != null) {
      _navigatorKey.currentState.pushNamed("/newNote/$_pendingShortcut");
      _pendingShortcut = null;
    }
  }

  void _initShareSubscriptions() {
    var handleShare = () {
      if (_sharedText == null && _sharedImages == null) {
        return;
      }

      var settings = Provider.of<Settings>(context, listen: false);
      var editor = settings.defaultEditor.toInternalString();
      _navigatorKey.currentState.pushNamed("/newNote/$editor");
    };

    // For sharing images coming from outside the app while the app is in the memory
    _intentDataStreamSubscription = ReceiveSharingIntent.getMediaStream()
        .listen((List<SharedMediaFile> value) {
      if (value == null) return;
      Log.d("Received Share $value");

      setState(() {
        _sharedImages = value.map((f) => f.path)?.toList();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => handleShare());
    }, onError: (err) {
      Log.e("getIntentDataStream error: $err");
    });

    // For sharing images coming from outside the app while the app is closed
    ReceiveSharingIntent.getInitialMedia().then((List<SharedMediaFile> value) {
      if (value == null) return;
      Log.d("Received Share with App running $value");

      setState(() {
        _sharedImages = value.map((f) => f.path)?.toList();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => handleShare());
    });

    // For sharing or opening text coming from outside the app while the app is in the memory
    _intentDataStreamSubscription =
        ReceiveSharingIntent.getTextStream().listen((String value) {
      Log.d("Received Share $value");
      setState(() {
        _sharedText = value;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => handleShare());
    }, onError: (err) {
      Log.e("getLinkStream error: $err");
    });

    // For sharing or opening text coming from outside the app while the app is closed
    ReceiveSharingIntent.getInitialText().then((String value) {
      Log.d("Received Share with App running $value");
      setState(() {
        _sharedText = value;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => handleShare());
    });
  }

  @override
  void dispose() {
    _intentDataStreamSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DynamicTheme(
      defaultBrightness: Brightness.dark,
      data: (b) => b == Brightness.light ? Themes.light : Themes.dark,
      themedWidgetBuilder: buildApp,
    );
  }

  MaterialApp buildApp(BuildContext context, ThemeData themeData) {
    var stateContainer = Provider.of<StateContainer>(context);
    var settings = Provider.of<Settings>(context);
    var appSettings = Provider.of<AppSettings>(context);
    var router = AppRouter(settings: settings, appSettings: appSettings);

    return MaterialApp(
      key: const ValueKey("App"),
      navigatorKey: _navigatorKey,
      title: 'Notium',

      localizationsDelegates: EasyLocalization.of(context).delegates,
      supportedLocales: EasyLocalization.of(context).supportedLocales,
      locale: EasyLocalization.of(context).locale,

      theme: themeData,
      navigatorObservers: <NavigatorObserver>[
        EventLogRouteObserver(),
      ],
      initialRoute: router.initialRoute(),
      debugShowCheckedModeBanner: false,
      //debugShowMaterialGrid: true,
      onGenerateRoute: (rs) => router.generateRoute(rs, stateContainer, _sharedText, _sharedImages),
    );
  }
}
