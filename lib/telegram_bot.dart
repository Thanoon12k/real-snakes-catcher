import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'clips.dart';

class Subscriber {
  final String id, name;
  const Subscriber(this.id, this.name);
  Map<String, String> toJson() => {'id': id, 'name': name};
}

/// Talks to the Telegram bot.
///
/// * On motion: sends the first photo + a message to every subscriber.
/// * Videos are never pushed automatically; a subscriber taps
///   "Get full video" (or sends /video) and only that person gets it.
/// * People subscribe by sending `/start <join code>` to the bot.
class TelegramBot extends ChangeNotifier {
  /// Telegram refuses bot uploads bigger than 50 MB.
  static const maxUpload = 50 * 1024 * 1024;

  String token = '', joinCode = '', ownerChatId = '';
  bool enabled = false;
  List<Subscriber> subscribers = [];
  String lastError = '';

  /// Set by the guard screen.
  bool Function(String id) isRecording = (_) => false;
  String? Function() currentRecordingId = () => null;
  String Function() statusText = () => '';

  final Map<String, Set<String>> _waitingForVideo = {};
  int _offset = 0, _pollGeneration = 0;

  bool get ready => enabled && token.isNotEmpty;

  Set<String> get recipients => {
        if (ownerChatId.isNotEmpty) ownerChatId,
        for (final s in subscribers) s.id,
      };

  bool isSubscribed(String chatId) => recipients.contains(chatId);

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    token = p.getString('botToken') ?? '';
    ownerChatId = p.getString('chatId') ?? '';
    enabled = p.getBool('telegramEnabled') ?? false;
    joinCode = p.getString('joinCode') ?? '';
    _offset = p.getInt('updateOffset') ?? 0;
    final raw = p.getString('subscribers');
    if (raw != null) {
      subscribers = [
        for (final m in jsonDecode(raw) as List)
          Subscriber('${m['id']}', '${m['name']}')
      ];
    }
    notifyListeners();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('botToken', token);
    await p.setString('chatId', ownerChatId);
    await p.setBool('telegramEnabled', enabled);
    await p.setString('joinCode', joinCode);
    await p.setString(
        'subscribers', jsonEncode([for (final s in subscribers) s.toJson()]));
    notifyListeners();
  }

  // ---------------------------------------------------------------- API

  Uri _api(String method) =>
      Uri.parse('https://api.telegram.org/bot${token.trim()}/$method');

  Future<Map<String, dynamic>?> _call(String method, Map<String, String> body,
      {Duration timeout = const Duration(seconds: 20)}) async {
    try {
      final r = await http.post(_api(method), body: body).timeout(timeout);
      final json = jsonDecode(r.body) as Map<String, dynamic>;
      if (json['ok'] != true) lastError = '${json['description']}';
      return json;
    } catch (e) {
      lastError = '$e';
      return null;
    }
  }

  Future<bool> _upload(String method, Map<String, String> fields,
      http.MultipartFile file, Duration timeout) async {
    try {
      final req = http.MultipartRequest('POST', _api(method))
        ..fields.addAll(fields)
        ..files.add(file);
      final res = await req.send().timeout(timeout);
      final json = jsonDecode(await res.stream.bytesToString()) as Map;
      if (json['ok'] != true) lastError = '${json['description']}';
      return json['ok'] == true;
    } catch (e) {
      lastError = '$e';
      return false;
    }
  }

  Future<bool> sendText(String chatId, String text, {String? markup}) async =>
      (await _call('sendMessage', {
        'chat_id': chatId,
        'text': text,
        if (markup != null) 'reply_markup': markup,
      }))?['ok'] ==
      true;

  static String _videoButton(String id) => jsonEncode({
        'inline_keyboard': [
          [
            {
              'text': '🎥 Get full video / الفيديو الكامل',
              'callback_data': 'v:$id'
            }
          ]
        ]
      });

  // ------------------------------------------------------------ alerts

  /// Sends the motion photo to every subscriber. Returns how many got it.
  Future<int> sendMotionAlert(String id, Uint8List? jpeg) async {
    if (!ready) return 0;
    final caption = '🐍 Snake Catcher — motion detected / تم اكتشاف حركة\n'
        '🕐 ${_time(DateTime.now())}\n'
        '🔴 Recording… tap the button for the full video.';
    int sent = 0;
    for (final chat in recipients) {
      final ok = jpeg == null
          ? await sendText(chat, caption, markup: _videoButton(id))
          : await _upload(
              'sendPhoto',
              {
                'chat_id': chat,
                'caption': caption,
                'reply_markup': _videoButton(id)
              },
              http.MultipartFile.fromBytes('photo', jpeg,
                  filename: 'motion_$id.jpg'),
              const Duration(seconds: 30));
      if (ok) sent++;
    }
    return sent;
  }

  Future<int> sendTestMessage() async {
    int sent = 0;
    for (final chat in recipients) {
      if (await sendText(chat, '✅ Snake Catcher is connected / متصل بنجاح')) {
        sent++;
      }
    }
    return sent;
  }

  /// Called when a clip has been saved; sends it to people who asked
  /// for it while it was still recording.
  Future<void> clipReady(String id) async {
    final waiting = _waitingForVideo.remove(id);
    if (waiting == null) return;
    for (final chat in waiting) {
      await _sendVideo(chat, id);
    }
  }

  /// Sends one clip to one chat (also used by the Recordings screen).
  Future<bool> sendVideoTo(String chatId, String id) => _sendVideo(chatId, id);

  Future<bool> _sendVideo(String chatId, String id) async {
    final file = await Clips.fileFor(id);
    if (!await file.exists()) {
      await sendText(
          chatId, '❌ Video $id not found (it may have been deleted).');
      return false;
    }
    final size = await file.length();
    if (size > maxUpload) {
      await sendText(
          chatId,
          '⚠️ Video $id is ${Clips.sizeText(size)}, over Telegram\'s 50 MB '
          'bot limit. It is saved on the phone (Gallery → ${Clips.galleryAlbum}).');
      return false;
    }
    unawaited(
        _call('sendChatAction', {'chat_id': chatId, 'action': 'upload_video'}));
    final ok = await _upload(
        'sendVideo',
        {
          'chat_id': chatId,
          'caption': '🎥 Snake Catcher — $id (${Clips.sizeText(size)})',
          'supports_streaming': 'true',
        },
        await http.MultipartFile.fromPath('video', file.path,
            filename: 'snake_$id.mp4'),
        const Duration(minutes: 5));
    if (!ok) await sendText(chatId, '❌ Sending failed: $lastError');
    return ok;
  }

  Future<void> _requestVideo(String chatId, String? id) async {
    id ??= currentRecordingId() ?? await _latestSavedId();
    if (id == null) {
      await sendText(chatId, 'No recordings yet. / لا توجد تسجيلات بعد');
      return;
    }
    if (isRecording(id)) {
      _waitingForVideo.putIfAbsent(id, () => {}).add(chatId);
      await sendText(chatId,
          '⏳ Still recording $id — I\'ll send it as soon as it finishes.');
      return;
    }
    await _sendVideo(chatId, id);
  }

  Future<String?> _latestSavedId() async {
    final files = await Clips.list();
    return files.isEmpty ? null : Clips.idOf(files.first);
  }

  // ----------------------------------------------------------- polling

  /// (Re)starts listening for messages sent to the bot.
  void restartPolling() {
    final gen = ++_pollGeneration;
    if (ready) unawaited(_poll(gen));
  }

  void stopPolling() => _pollGeneration++;

  Future<void> _poll(int gen) async {
    while (gen == _pollGeneration && ready) {
      try {
        final r = await http.post(_api('getUpdates'), body: {
          'offset': '$_offset',
          'timeout': '25',
          'allowed_updates': '["message","callback_query"]',
        }).timeout(const Duration(seconds: 40));
        if (gen != _pollGeneration) return;
        final json = jsonDecode(r.body) as Map<String, dynamic>;
        if (json['ok'] != true) {
          lastError = '${json['description']}';
          // A webhook blocks getUpdates; remove it so the app can listen.
          if (r.statusCode == 409 && lastError.contains('webhook')) {
            await _call('deleteWebhook', {});
          }
          await Future.delayed(const Duration(seconds: 10));
          continue;
        }
        for (final u in json['result'] as List) {
          _offset = (u['update_id'] as int) + 1;
          try {
            await _handle(u as Map<String, dynamic>);
          } catch (e) {
            debugPrint('Telegram update failed: $e');
          }
        }
        (await SharedPreferences.getInstance()).setInt('updateOffset', _offset);
      } catch (e) {
        lastError = '$e';
        await Future.delayed(const Duration(seconds: 5));
      }
    }
  }

  Future<void> _handle(Map<String, dynamic> u) async {
    final cq = u['callback_query'];
    if (cq != null) {
      final chatId = '${cq['message']?['chat']?['id'] ?? cq['from']['id']}';
      final data = '${cq['data'] ?? ''}';
      await _call('answerCallbackQuery', {
        'callback_query_id': '${cq['id']}',
        'text': isSubscribed(chatId) ? 'Preparing video…' : 'Not subscribed',
      });
      if (!isSubscribed(chatId)) return;
      if (data.startsWith('v:')) await _requestVideo(chatId, data.substring(2));
      return;
    }

    final msg = u['message'];
    if (msg == null) return;
    final chatId = '${msg['chat']['id']}';
    final from = msg['from'] ?? {};
    final name = [from['first_name'], from['last_name'], msg['chat']['title']]
        .where((s) => s != null)
        .join(' ');
    final text = '${msg['text'] ?? ''}'.trim();
    final parts = text.split(RegExp(r'\s+'));
    final command = parts.first.split('@').first.toLowerCase();
    final arg = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    if (!isSubscribed(chatId)) {
      final code = command == '/start' ? arg : text;
      if (joinCode.isNotEmpty && code == joinCode) {
        subscribers.add(Subscriber(chatId, name.isEmpty ? chatId : name));
        await save();
        await sendText(
            chatId,
            '✅ Subscribed! You will get a photo whenever '
            'motion is detected.\n\n$_help');
      } else {
        await sendText(
            chatId,
            joinCode.isEmpty
                ? '🔒 This bot is private. The owner has not set a join code yet.'
                : '🔒 This bot is private. Send /start followed by the join code.\n'
                    'خاص. أرسل /start ثم رمز الانضمام.');
      }
      return;
    }

    if (command == '/stop') {
      subscribers.removeWhere((s) => s.id == chatId);
      await save();
      await sendText(
          chatId,
          chatId == ownerChatId
              ? 'You are the owner chat; turn this off in the app settings.'
              : '👋 Unsubscribed. Send /start <code> to join again.');
    } else if (command.startsWith('/video_')) {
      await _requestVideo(chatId, command.substring(7));
    } else if (command == '/video' ||
        text.toLowerCase().contains('video') ||
        text.contains('فيديو')) {
      await _requestVideo(chatId, arg.isEmpty ? null : arg);
    } else if (command == '/list') {
      final files = (await Clips.list()).take(10).toList();
      await sendText(
          chatId,
          files.isEmpty
              ? 'No recordings yet.'
              : 'Latest recordings (tap to get one):\n'
                  '${files.map((f) => '/video_${Clips.idOf(f)}').join('\n')}');
    } else if (command == '/status') {
      await sendText(chatId, statusText());
    } else {
      await sendText(chatId, _help);
    }
  }

  static const _help = '🐍 Snake Catcher commands:\n'
      '/video — full video of the latest motion\n'
      '/list — last 10 recordings\n'
      '/status — is the guard on?\n'
      '/stop — stop receiving alerts\n'
      'Or tap "Get full video" under any alert photo.';

  static String _time(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// Exposed for the settings screen.
  Future<void> removeSubscriber(Subscriber s) async {
    subscribers.removeWhere((x) => x.id == s.id);
    await save();
    await sendText(s.id, '👋 The owner removed you from Snake Catcher alerts.');
  }
}
