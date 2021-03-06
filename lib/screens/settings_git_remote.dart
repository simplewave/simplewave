import 'dart:io';

import 'package:dart_git/dart_git.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:notium/repository.dart';
import 'package:notium/screens/settings_widgets.dart';
import 'package:notium/settings.dart';
import 'package:notium/setup/screens.dart';
import 'package:notium/setup/sshkey.dart';
import 'package:notium/ssh/keygen.dart';
import 'package:notium/utils.dart';
import 'package:notium/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

class GitRemoteSettingsScreen extends StatefulWidget {
  final String sshPublicKey;
  GitRemoteSettingsScreen(this.sshPublicKey);

  @override
  _GitRemoteSettingsScreenState createState() =>
      _GitRemoteSettingsScreenState();
}

class _GitRemoteSettingsScreenState extends State<GitRemoteSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    var textTheme = Theme.of(context).textTheme;
    var settings = Provider.of<Settings>(context);

    var body = Column(
      children: <Widget>[
        Text(
          tr('setup.sshKeyUserProvided.public'),
          style: textTheme.bodyText1,
          textAlign: TextAlign.left,
        ),
        const SizedBox(height: 16.0),
        PublicKeyWidget(widget.sshPublicKey),
        const SizedBox(height: 16.0),
        const Divider(),
        Builder(
          builder: (BuildContext context) => Button(
            text: tr('setup.sshKey.copy'),
            onPressed: () => _copyKeyToClipboard(context),
          ),
        ),
        Builder(
          builder: (BuildContext context) => Button(
            text: tr('setup.sshKey.regenerate'),
            onPressed: () => _generateSshKey(context),
          ),
        ),
        ListPreference(
          title: tr('settings.ssh.syncFreq'),
          currentOption: settings.remoteSyncFrequency.toPublicString(),
          options: RemoteSyncFrequency.options
              .map((f) => f.toPublicString())
              .toList(),
          onChange: (String publicStr) {
            var val = RemoteSyncFrequency.fromPublicString(publicStr);
            settings.remoteSyncFrequency = val;
            settings.save();
            setState(() {});
          },
        ),
        RedButton(
          text: tr('settings.ssh.reset'),
          onPressed: _resetGitHost,
        ),
      ],
      crossAxisAlignment: CrossAxisAlignment.start,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(tr("settings.gitRemote.title")),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: body,
      ),
    );
  }

  void _copyKeyToClipboard(BuildContext context) {
    Clipboard.setData(ClipboardData(text: widget.sshPublicKey));
    showSnackbar(context, tr('setup.sshKey.copied'));
  }

  void _generateSshKey(BuildContext context) {
    var comment = "notium-" +
        Platform.operatingSystem +
        "-" +
        DateTime.now().toIso8601String().substring(0, 10); // only the date

    generateSSHKeys(comment: comment).then((SshKey sshKey) {
      var settings = Provider.of<Settings>(context, listen: false);
      settings.sshPublicKey = sshKey.publicKey;
      settings.sshPrivateKey = sshKey.publicKey;
      settings.sshPassword = sshKey.password;
      settings.save();

      Log.d("PublicKey: " + sshKey.publicKey);
      _copyKeyToClipboard(context);
    });
  }

  void _resetGitHost() async {
    var ok = await showDialog(
      context: context,
      builder: (_) => HostChangeConfirmationDialog(),
    );
    if (ok == null) {
      return;
    }

    var repo = Provider.of<Repository>(context, listen: false);
    var gitDir = repo.gitBaseDirectory;

    // Figure out the next available folder
    String repoFolderName = "notium_";
    var num = 0;
    while (true) {
      var repoFolderPath = p.join(gitDir, "$repoFolderName$num");
      if (!Directory(repoFolderPath).existsSync()) {
        await GitRepository.init(repoFolderPath);
        break;
      }
      num++;
    }
    repoFolderName = repoFolderName + num.toString();

    var route = MaterialPageRoute(
      builder: (context) => GitHostSetupScreen(
        repoFolderName: repoFolderName,
        remoteName: 'origin',
        onCompletedFunction: repo.completeGitHostSetup,
      ),
      settings: const RouteSettings(name: '/setupRemoteGit'),
    );
    await Navigator.of(context).push(route);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

class Button extends StatelessWidget {
  final String text;
  final Function onPressed;

  Button({@required this.text, @required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FlatButton(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.button,
        ),
        color: Theme.of(context).primaryColor,
        onPressed: onPressed,
      ),
    );
  }
}

class RedButton extends StatelessWidget {
  final String text;
  final Function onPressed;

  RedButton({@required this.text, @required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FlatButton(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.button,
        ),
        color: Colors.red,
        onPressed: onPressed,
      ),
    );
  }
}

class HostChangeConfirmationDialog extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr("settings.gitRemote.changeHost.title")),
      content: Text(tr("settings.gitRemote.changeHost.subtitle")),
      actions: <Widget>[
        FlatButton(
          child: Text(tr("settings.gitRemote.changeHost.ok")),
          onPressed: () => Navigator.of(context).pop(true),
        ),
        FlatButton(
          child: Text(tr("settings.gitRemote.changeHost.cancel")),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
