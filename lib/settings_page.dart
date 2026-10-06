import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'telegram_bot.dart';

class SettingsPage extends StatefulWidget {
  final TelegramBot bot;
  final String cameraMode;
  const SettingsPage({super.key, required this.bot, required this.cameraMode});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final token = TextEditingController(text: widget.bot.token);
  late final code = TextEditingController(text: widget.bot.joinCode);
  late final owner = TextEditingController(text: widget.bot.ownerChatId);
  late bool enabled = widget.bot.enabled;
  late String cameraMode = widget.cameraMode;
  bool testing = false;

  @override
  void initState() {
    super.initState();
    widget.bot.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.bot.removeListener(_refresh);
    token.dispose();
    code.dispose();
    owner.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _save({bool close = true}) async {
    final bot = widget.bot
      ..token = token.text.trim()
      ..joinCode = code.text.trim()
      ..ownerChatId = owner.text.trim()
      ..enabled = enabled;
    await bot.save();
    bot.restartPolling();
    await (await SharedPreferences.getInstance())
        .setString('cameraMode', cameraMode);
    if (close && mounted) Navigator.pop(context, cameraMode);
  }

  Future<void> _test() async {
    setState(() => testing = true);
    await _save(close: false);
    final sent = await widget.bot.sendTestMessage();
    if (!mounted) return;
    setState(() => testing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(sent > 0
            ? 'Test message sent to $sent chat(s).'
            : 'Nothing sent. ${widget.bot.recipients.isEmpty ? 'No subscribers yet.' : widget.bot.lastError}')));
  }

  @override
  Widget build(BuildContext context) {
    final subs = widget.bot.subscribers;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Camera', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
                value: 'day', icon: Icon(Icons.wb_sunny), label: Text('Day')),
            ButtonSegment(
                value: 'night',
                icon: Icon(Icons.nightlight),
                label: Text('Night')),
          ],
          selected: {cameraMode},
          onSelectionChanged: (v) => setState(() => cameraMode = v.first),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
              'Night mode reacts to smaller brightness changes (dark rooms).',
              style: TextStyle(fontSize: 12, color: Colors.white70)),
        ),
        const Divider(height: 32),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Telegram alerts'),
          subtitle: const Text(
              'Sends the first photo of each motion to all subscribers. '
              'Videos are only sent when someone asks for one.'),
          value: enabled,
          onChanged: (v) => setState(() => enabled = v),
        ),
        TextField(
          controller: token,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
              labelText: 'Bot token', hintText: '123456:ABC...'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: code,
          autocorrect: false,
          decoration: const InputDecoration(
              labelText: 'Join code (secret)',
              helperText:
                  'People subscribe by sending:  /start <join code>  to the bot',
              helperMaxLines: 2),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: owner,
          keyboardType: TextInputType.text,
          decoration: const InputDecoration(
              labelText: 'Your chat ID (optional)',
              helperText: 'Always gets alerts, without needing the join code.'),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: testing ? null : _test,
              icon: const Icon(Icons.send),
              label: const Text('Save & send test'),
            ),
          ),
        ]),
        if (widget.bot.lastError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Last Telegram error: ${widget.bot.lastError}',
                style:
                    const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
          ),
        const Divider(height: 32),
        Text('Subscribers (${subs.length})',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        if (subs.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
                'Nobody yet. Share the bot link and the join code with your family.',
                style: TextStyle(color: Colors.white70)),
          ),
        for (final s in subs)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person),
            title: Text(s.name),
            subtitle: Text(s.id),
            trailing: IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.person_remove),
              onPressed: () => widget.bot.removeSubscriber(s),
            ),
          ),
        const SizedBox(height: 24),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ]),
    );
  }
}
