import 'dart:io';

import 'package:dart_git/git.dart';
import 'package:dots_indicator/dots_indicator.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:function_types/function_types.dart';
import 'package:git_bindings/git_bindings.dart' as git_bindings;
import 'package:notium/apis/githost_factory.dart';
import 'package:notium/error_reporting.dart';
import 'package:notium/event_logger.dart';
import 'package:notium/repository.dart';
import 'package:notium/settings.dart';
import 'package:notium/setup/button.dart';
import 'package:notium/setup/clone_url.dart';
import 'package:notium/setup/loading_error.dart';
import 'package:notium/setup/sshkey.dart';
import 'package:notium/ssh/keygen.dart';
import 'package:notium/utils.dart';
import 'package:notium/utils/logger.dart';
import 'package:notium/utils/notium_urls.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

class GitHostSetupScreen extends StatefulWidget {
  final String repoFolderName;
  final String remoteName;
  final Func2<String, String, void> onCompletedFunction;

  GitHostSetupScreen({
    @required this.repoFolderName,
    @required this.remoteName,
    @required this.onCompletedFunction,
  });

  @override
  GitHostSetupScreenState createState() {
    return GitHostSetupScreenState();
  }
}

enum AccountProviderChoice { Unknown, KnownProvider, CustomProvider }
enum KeyGenerationChoice { Unknown, AutoGenerated }
enum GitHostSetupType { Manual }

class GitHostSetupScreenState extends State<GitHostSetupScreen> {
  var _pageCount = 1;

  var _setupPagesChoices = [
    AccountProviderChoice.Unknown,
  ];
  var _keyGenerationChoice = KeyGenerationChoice.Unknown;

  var _gitHostType = GitHostType.Unknown;
  GitHost _gitHost;
  GitHostRepo _gitHostRepo;
  String _autoConfigureMessage = "";
  String _autoConfigureErrorMessage = "";

  var _gitCloneUrl = "";
  var gitCloneErrorMessage = "";
  var publicKey = "";

  String _pageTitle = tr('setup.gitSetupIntro.title');

  var pageController = PageController();
  int _currentPageIndex = 0;

  Widget _buildPage(BuildContext context, int pos) {
    assert(_pageCount >= 1);

    if (pos == 0) {
      _pageTitle = tr('setup.gitSetupIntro.title');
      return GitSetupIntroPage(
        onConfirm: () {
          setState(() {
            _pageCount = pos + 2;
            _nextPage();
          });
        },
      );
    }

    if (pos == 1) {
      _pageTitle = tr('setup.host.title');
      return GitHostChoicePage(
        onKnownGitHost: (GitHostType gitHostType) {
          setState(() {
            _gitHostType = gitHostType;
            gitCloneErrorMessage = "";
            _autoConfigureErrorMessage = "";
            _autoConfigureMessage = "";

            _setupPagesChoices[0] = AccountProviderChoice.KnownProvider;
            _pageCount = pos + 2;
            _nextPage();
          });
        },
        onCustomGitHost: () {
          setState(() {
            _setupPagesChoices[0] = AccountProviderChoice.CustomProvider;
            _pageCount = pos + 2;
            _nextPage();
          });
        },
      );
    }

    if (pos == 2) {
      _pageTitle = tr('setup.cloneUrl.manual.title');
      return GitCloneUrlKnownProviderPage(
        doneFunction: (String sshUrl) {
          setState(() {
            _pageCount = pos + 2;
            _gitCloneUrl = sshUrl;
            _keyGenerationChoice = KeyGenerationChoice.AutoGenerated;

            _nextPage();
            _generateSshKey(context);
          });
        },
        launchCreateUrlPage: _launchCreateRepoPage,
        gitHostType: _gitHostType,
        initialValue: _gitCloneUrl,
      );
    }

    if (pos == 3) {
      _pageTitle = tr('setup.sshKey.title');
      assert(_keyGenerationChoice != KeyGenerationChoice.Unknown);
      if (_keyGenerationChoice == KeyGenerationChoice.AutoGenerated) {
        return GitHostSetupSshKeyKnownProvider(
          doneFunction: () {
            setState(() {
              _pageCount = 6;

              _nextPage();
              _startGitClone(context);
            });
          },
          regenerateFunction: () {
            setState(() {
              publicKey = "";
            });
            _generateSshKey(context);
          },
          publicKey: publicKey,
          copyKeyFunction: _copyKeyToClipboard,
          openDeployKeyPage: _launchDeployKeyPage,
        );
      }
    }

    if (pos == 4) {
      return GitHostSetupLoadingErrorPage(
        loadingMessage: tr('setup.cloning'),
        errorMessage: gitCloneErrorMessage,
      );
    }

    assert(_setupPagesChoices[0] != AccountProviderChoice.CustomProvider);

    assert(false, "Pos is $pos");
    return null;
  }

  @override
  Widget build(BuildContext context) {
    var pageView = PageView.builder(
      controller: pageController,
      itemBuilder: _buildPage,
      itemCount: _pageCount,
      onPageChanged: (int pageNum) {
        setState(() {
          _currentPageIndex = pageNum;
          _pageCount = _currentPageIndex + 1;
        });
      },
    );

    var body = Container(
      width: double.infinity,
      height: double.infinity,
      child: Stack(
        alignment: FractionalOffset.bottomCenter,
        children: <Widget>[
          pageView,
          DotsIndicator(
            dotsCount: _pageCount,
            position: _currentPageIndex,
            decorator: DotsDecorator(
              activeColor: Theme.of(context).primaryColorDark,
            ),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16.0),
    );

    var scaffold = Scaffold(
      appBar: AppBar(
        title: Text(_pageTitle),
        leading: IconButton(
          key: const ValueKey("Cancel"),
          icon: const Icon(Icons.close_outlined),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
        actions: <Widget>[

        ],
      ),
      body: Stack(
        children: <Widget>[
          body,
        ],
      ),
    );

    return WillPopScope(
      onWillPop: () async {
        if (_currentPageIndex != 0) {
          pageController.previousPage(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeIn,
          );
          return false;
        }

        return true;
      },
      child: scaffold,
    );
  }

  void _nextPage() {
    pageController.nextPage(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeIn,
    );
  }

  void _generateSshKey(BuildContext context) {
    if (publicKey.isNotEmpty) {
      return;
    }

    var comment = "notium-" +
        Platform.operatingSystem +
        "-" +
        DateTime.now().toIso8601String().substring(0, 10); // only the date

    generateSSHKeys(comment: comment).then((SshKey sshKey) {
      var settings = Provider.of<Settings>(context, listen: false);
      settings.sshPublicKey = sshKey.publicKey;
      settings.sshPrivateKey = sshKey.privateKey;
      settings.sshPassword = sshKey.password;
      settings.save();

      setState(() {
        this.publicKey = sshKey.publicKey;
        Log.d("PublicKey: " + publicKey);
      });
    });
  }

  void _copyKeyToClipboard(BuildContext context) {
    Clipboard.setData(ClipboardData(text: publicKey));
    showSnackbar(context, tr('setup.sshKey.copied'));
  }

  void _launchDeployKeyPage() async {
    var lastIndex = _gitCloneUrl.lastIndexOf(".git");
    if (lastIndex == -1) {
      lastIndex = _gitCloneUrl.length;
    }

    var repoName =
        _gitCloneUrl.substring(_gitCloneUrl.lastIndexOf(":") + 1, lastIndex);

    try {
      if (_gitCloneUrl.startsWith("git@github.com:")) {
        Log.d(NotiumUrls.notiumURLs.toString());
        var gitHubUrl = NotiumUrls.notiumURLs['githubBaseUrl'] + "/" + repoName + NotiumUrls.notiumURLs['newGithubKeySuffix'];
        Log.i("Launching $gitHubUrl");
        await launch(gitHubUrl);
      } else if (_gitCloneUrl.startsWith("git@gitlab.com:")) {
        var gitLabUrl = NotiumUrls.notiumURLs['gitlabBaseUrl'] + "/" + repoName + NotiumUrls.notiumURLs['newGitlabKeySuffix'];
        Log.i("Launching $gitLabUrl");
        await launch(gitLabUrl);
      } else {
        Log.d("Launching custom provider URL domain for new key");
        var domain = _gitCloneUrl.substring(_gitCloneUrl.indexOf('@')+1, _gitCloneUrl.indexOf(':')); // position +1 to avoid getting the @
        Log.d(domain);
        var customProviderUrl = "https://" + domain;
        Log.d(customProviderUrl);
        await launch(customProviderUrl);
      }
    } catch (err, stack) {
      Log.d('_launchDeployKeyPage: ' + err.toString());
      Log.d(stack.toString());
    }
  }

  void _launchCreateRepoPage() async {
    assert(_gitHostType != GitHostType.Unknown);

    try {
      if (_gitHostType == GitHostType.GitHub) {
        await launch(NotiumUrls.notiumURLs['newGithubRepo']);
      } else if (_gitHostType == GitHostType.GitLab) {
        await launch(NotiumUrls.notiumURLs['newGitlabRepo']);
      }
    } catch (err, stack) {
      // FIXME: Error handling?
      Log.d("_launchCreateRepoPage: " + err.toString());
      Log.d(stack.toString());
    }
  }

  void _startGitClone(BuildContext context) async {
    setState(() {
      gitCloneErrorMessage = "";
    });

    var repo = Provider.of<Repository>(context, listen: false);
    var basePath = repo.gitBaseDirectory;

    var settings = Provider.of<Settings>(context, listen: false);
    var repoPath = p.join(basePath, widget.repoFolderName);
    Log.i("RepoPath: $repoPath");

    String error;
    try {
      var repo = await GitRepository.load(repoPath);
      await repo.addRemote(widget.remoteName, _gitCloneUrl);

      var repoN = git_bindings.GitRepo(folderPath: repoPath);
      await repoN.fetch(
        remote: widget.remoteName,
        publicKey: settings.sshPublicKey,
        privateKey: settings.sshPrivateKey,
        password: settings.sshPassword,
      );
    } on Exception catch (e) {
      Log.e(e.toString());
      error = e.toString();
    }

    if (error != null && error.isNotEmpty) {
      Log.i("Not completing gitClone because of error");
      setState(() {
        logEvent(Event.GitHostSetupGitCloneError, parameters: {
          'error': error,
        });
        gitCloneErrorMessage = error;
      });
      return;
    }

    //
    // Add a GitIgnore file. This way we always at least have one commit
    // It makes doing a git pull and push easier
    //
    var dirList = await Directory(repoPath).list().toList();
    var anyFileInRepo = dirList.firstWhere(
          (fs) => fs.statSync().type == FileSystemEntityType.file,
      orElse: () => null,
    );
    if (anyFileInRepo == null) {
      Log.i("Adding .ignore file");
      var ignoreFile = File(p.join(repoPath, ".gitignore"));
      ignoreFile.createSync();

      var repo = git_bindings.GitRepo(folderPath: repoPath);
      await repo.add('.gitignore');

      var settings = Provider.of<Settings>(context, listen: false);
      await repo.commit(
        message: "Add gitignore file",
        authorEmail: settings.gitAuthorEmail,
        authorName: settings.gitAuthor,
      );
    }

    logEvent(
      Event.GitHostSetupComplete,
      parameters: _buildOnboardingLogInfo(),
    );
    Navigator.pop(context);
    widget.onCompletedFunction(widget.repoFolderName, widget.remoteName);
  }

  Future<void> _completeAutoConfigure() async {
    Log.d("Starting autoconfigure completion");

    try {
      Log.i("Generating SSH Key");
      setState(() {
        _autoConfigureMessage = tr('setup.sshKey.generate');
      });
      var sshKey = await generateSSHKeys(comment: "notium");
      var settings = Provider.of<Settings>(context, listen: false);
      settings.sshPublicKey = sshKey.publicKey;
      settings.sshPrivateKey = sshKey.privateKey;
      settings.sshPassword = sshKey.password;
      settings.save();

      setState(() {
        publicKey = sshKey.publicKey;
      });

      Log.i("Adding as a deploy key");
      _autoConfigureMessage = tr('setup.sshKey.addDeploy');

      await _gitHost.addDeployKey(publicKey, _gitHostRepo.fullName);
    } on Exception catch (e, stacktrace) {
      _handleGitHostException(e, stacktrace);
      return;
    }

    setState(() {
      _gitCloneUrl = _gitHostRepo.cloneUrl;
      _pageCount += 1;

      _nextPage();
      _startGitClone(context);
    });
  }

  void _handleGitHostException(Exception e, StackTrace stacktrace) {
    Log.d("GitHostSetupAutoConfigureComplete: " + e.toString());
    setState(() {
      _autoConfigureErrorMessage = e.toString();
      logEvent(
        Event.GitHostSetupError,
        parameters: {
          'errorMessage': _autoConfigureErrorMessage,
        },
      );

      logException(e, stacktrace);
    });
  }

  Map<String, String> _buildOnboardingLogInfo() {
    var map = <String, String>{};

    if (_gitCloneUrl.contains("github.com")) {
      map["host_type"] = "GitHub";
    } else if (_gitCloneUrl.contains("gitlab.org")) {
      map["host_type"] = "GitLab.org";
    } else if (_gitCloneUrl.contains("gitlab")) {
      map["host_type"] = "GitLab";
    }

    var ch0 = _setupPagesChoices[0] as AccountProviderChoice;
    map["provider_choice"] = ch0.toString().replaceFirst("PageChoice0.", "");

    map["key_generation"] = _keyGenerationChoice
        .toString()
        .replaceFirst("KeyGenerationChoice.", "");

    return map;
  }
}

class GitSetupIntroPage extends StatelessWidget {
  final Func0<void> onConfirm;

  GitSetupIntroPage({
    @required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(0, 0, 0, 32),
      child: Column(
        children: <Widget>[
          Text(
            tr('setup.gitSetupIntro.description'),
            style: Theme.of(context).textTheme.bodyText1,
          ),
          const SizedBox(height: 16.0),
          GitHostSetupButton(
            text: tr('setup.gitSetupIntro.confirm'),
            onPressed: () {
              onConfirm();
            },
          ),
        ],
      ),
    );
  }
}

class GitHostChoicePage extends StatelessWidget {
  final Func1<GitHostType, void> onKnownGitHost;
  final Func0<void> onCustomGitHost;

  GitHostChoicePage({
    @required this.onKnownGitHost,
    @required this.onCustomGitHost,
  });

  void _launchProviderInfoPage() async {
    var providerInfoUrl = NotiumUrls.notiumURLs['gitHostingProvidersInfo'];
    try {
      Log.i("Launching Git hosting providers info page");
      await launch(providerInfoUrl);
    } catch (err, stack) {
      Log.d('_launchProviderInfoPage: ' + err.toString());
      Log.d(stack.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(0, 0, 0, 32),
      child: Column(
        children: <Widget>[
          const SizedBox(height: 16.0),
          Text(
            tr('setup.host.description'),
            style: Theme.of(context).textTheme.bodyText1,
          ),
          GitHostSetupButton(
            text: "GitHub",
            iconUrl: 'assets/icon/github-icon.png',
            onPressed: () {
              onKnownGitHost(GitHostType.GitHub);
            },
          ),
          const SizedBox(height: 16.0),
          GitHostSetupButton(
            text: "GitLab",
            iconUrl: 'assets/icon/gitlab-icon.png',
            onPressed: () async {
              onKnownGitHost(GitHostType.GitLab);
            },
          ),
          const SizedBox(height: 16.0),
          GitHostSetupButton(
            text: tr('setup.host.custom'),
            onPressed: () async {
              onCustomGitHost();
            },
          ),
          const SizedBox(height: 16.0),
          GitHostSetupButton(
              text: tr('setup.host.helpMeChoose'),
              iconUrl: 'assets/icon/help-icon.png',
              onPressed: () {
                _launchProviderInfoPage();
              }
          ),
        ],
      ),
    );
  }
}

class GitHostAutoConfigureChoicePage extends StatelessWidget {
  final Func1 onDone;

  GitHostAutoConfigureChoicePage({@required this.onDone});

  @override
  Widget build(BuildContext context) {
    return Container(
      child: Column(
        children: <Widget>[
          Text(
            tr('setup.autoConfigure.title'),
            style: Theme.of(context).textTheme.headline5,
          ),
          const SizedBox(height: 16.0),
          const SizedBox(height: 8.0),
          GitHostSetupButton(
            text: tr('setup.autoConfigure.manual'),
            onPressed: () async {
              onDone(GitHostSetupType.Manual);
            },
          ),
        ],
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
      ),
    );
  }
}
