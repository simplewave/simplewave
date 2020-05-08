import 'dart:io';

import 'package:device_info/device_info.dart';
import 'package:firebase_analytics/observer.dart';
import 'package:flutter/material.dart';
import 'package:gitjournal/analytics.dart';
import 'package:gitjournal/screens/folder_listing.dart';
import 'package:gitjournal/screens/purchase_screen.dart';
import 'package:gitjournal/screens/purchase_thankyou_screen.dart';
import 'package:gitjournal/utils/logger.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_runtime_env/flutter_runtime_env.dart' as runtime_env;

import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization_loader/easy_localization_loader.dart';

import 'package:git_bindings/git_bindings.dart';

import 'package:gitjournal/apis/git.dart';
import 'package:gitjournal/settings.dart';
import 'package:gitjournal/state_container.dart';
import 'package:gitjournal/appstate.dart';
import 'package:gitjournal/themes.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:dynamic_theme/dynamic_theme.dart';

import 'screens/home_screen.dart';
import 'screens/onboarding_screens.dart';
import 'screens/settings_screen.dart';
import 'setup/screens.dart';

class JournalApp extends StatelessWidget {
  static Future main(SharedPreferences pref) async {
    await Log.init();

    var appState = AppState(pref);
    appState.dumpToLog();

    Log.i("Setting ${Settings.instance.toLoggableMap()}");

    if (Settings.instance.collectUsageStatistics) {
      _enableAnalyticsIfPossible();
    }

    if (appState.gitBaseDirectory.isEmpty) {
      var dir = await getGitBaseDirectory();
      appState.gitBaseDirectory = dir.path;
      appState.save(pref);
    }

    if (appState.localGitRepoConfigured == false) {
      // FIXME: What about exceptions!
      appState.localGitRepoFolderName = "journal_local";
      var repoPath = p.join(
        appState.gitBaseDirectory,
        appState.localGitRepoFolderName,
      );
      await GitRepo.init(repoPath);

      appState.localGitRepoConfigured = true;
      appState.save(pref);
    }

    var app = ChangeNotifierProvider(
      create: (_) {
        return StateContainer(appState);
      },
      child: ChangeNotifierProvider(
        child: JournalApp(),
        create: (_) {
          assert(appState.notesFolder != null);
          return appState.notesFolder;
        },
      ),
    );

    runApp(EasyLocalization(
      child: app,
      supportedLocales: [const Locale('en', 'US')],
      path: 'assets/langs',
      useOnlyLangCode: true,
      assetLoader: YamlAssetLoader(),
    ));
  }

  static void _enableAnalyticsIfPossible() async {
    JournalApp.isInDebugMode = runtime_env.isInDebugMode();

    var isPhysicalDevice = true;
    try {
      DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        var info = await deviceInfo.androidInfo;
        isPhysicalDevice = info.isPhysicalDevice;
        Log.d("Device Fingerprint: " + info.fingerprint);
      } else if (Platform.isIOS) {
        var info = await deviceInfo.iosInfo;
        isPhysicalDevice = info.isPhysicalDevice;
      }
    } catch (e) {
      Log.d(e);
    }

    if (isPhysicalDevice == false) {
      JournalApp.isInDebugMode = true;
    }

    bool inFireBaseTestLab = await runtime_env.inFirebaseTestLab();
    bool enabled = !JournalApp.isInDebugMode && !inFireBaseTestLab;

    Log.d("Analytics Collection: $enabled");
    JournalApp.analytics.setAnalyticsCollectionEnabled(enabled);

    if (enabled) {
      JournalApp.analytics.logEvent(
        name: "settings",
        parameters: Settings.instance.toLoggableMap(),
      );
    }
  }

  static final analytics = Analytics();
  static FirebaseAnalyticsObserver observer =
      FirebaseAnalyticsObserver(analytics: analytics.firebase);

  static bool isInDebugMode = false;

  @override
  Widget build(BuildContext context) {
    return DynamicTheme(
      defaultBrightness: Brightness.light,
      data: (b) => b == Brightness.light ? Themes.light : Themes.dark,
      themedWidgetBuilder: buildApp,
    );
  }

  MaterialApp buildApp(BuildContext context, ThemeData themeData) {
    var stateContainer = Provider.of<StateContainer>(context);

    var initialRoute = '/';
    if (!stateContainer.appState.onBoardingCompleted) {
      initialRoute = '/onBoarding';
    }

    return MaterialApp(
      key: const ValueKey("App"),
      title: 'GitJournal',

      localizationsDelegates: EasyLocalization.of(context).delegates,
      supportedLocales: EasyLocalization.of(context).supportedLocales,
      locale: EasyLocalization.of(context).locale,

      theme: themeData,
      navigatorObservers: <NavigatorObserver>[JournalApp.observer],
      initialRoute: initialRoute,
      debugShowCheckedModeBanner: false,
      //debugShowMaterialGrid: true,
      onGenerateRoute: (settings) {
        if (settings.name == '/folders') {
          return PageRouteBuilder(
            settings: settings,
            pageBuilder: (_, __, ___) =>
                _screenForRoute(settings.name, stateContainer),
            transitionsBuilder: (_, anim, __, child) {
              return FadeTransition(opacity: anim, child: child);
            },
          );
        }

        return MaterialPageRoute(
          settings: settings,
          builder: (context) => _screenForRoute(
            settings.name,
            stateContainer,
          ),
        );
      },
    );
  }

  Widget _screenForRoute(String route, StateContainer stateContainer) {
    switch (route) {
      case '/':
        return HomeScreen();
      case '/folders':
        return FolderListingScreen();
      case '/settings':
        return SettingsScreen();
      case '/setupRemoteGit':
        return GitHostSetupScreen(stateContainer.completeGitHostSetup);
      case '/onBoarding':
        return OnBoardingScreen(stateContainer.completeOnBoarding);
      case '/purchase':
        return PurchaseScreen();
      case '/purchase_thank_you':
        return PurchaseThankYouScreen();
    }

    assert(false, "Not found named route in _screenForRoute");
    return null;
  }
}
