import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

class RecordingsPage extends StatefulWidget {
  final String botToken;
  final String chatId;
  final bool telegramEnabled;

  const RecordingsPage({
    super.key,
    required this.botToken,
    required this.chatId,
    required this.telegramEnabled,
  });

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  List<File> files = [];
  bool loading = true;
  String? workingFile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Directory> _folder() async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/NightGuard');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    return folder;
  }

  Future<void> _load() async {
    final folder = await _folder();

    final result = folder
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp4'))
        .toList();

    result.sort(
      (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
    );

    if (!mounted) return;

    setState(() {
      files = result;
      loading = false;
    });
  }

  String _name(File file) {
    return file.path.split(Platform.pathSeparator).last;
  }

  Future<String> _telegramState(File file) async {
    final p = await SharedPreferences.getInstance();
    return p.getString('telegram_${_name(file)}') ?? 'pending';
  }

  Future<void> _setTelegramState(File file, String state) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('telegram_${_name(file)}', state);
  }

  Future<void> _delete(File file) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text(_name(file)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    try {
      if (await file.exists()) {
        await file.delete();
      }

      final p = await SharedPreferences.getInstance();
      await p.remove('telegram_${_name(file)}');

      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    }
  }

  Future<void> _send(File file) async {
    if (!widget.telegramEnabled ||
        widget.botToken.trim().isEmpty ||
        widget.chatId.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configure Telegram first.')),
      );
      return;
    }

    setState(() => workingFile = file.path);
    await _setTelegramState(file, 'sending');

    try {
      final uri = Uri.parse(
        'https://api.telegram.org/bot${widget.botToken.trim()}/sendVideo',
      );

      final request = http.MultipartRequest('POST', uri)
        ..fields['chat_id'] = widget.chatId.trim()
        ..fields['caption'] =
            'Night Guard recording\n${file.lastModifiedSync().toLocal()}'
        ..files.add(
          await http.MultipartFile.fromPath('video', file.path),
        );

      final response = await request.send().timeout(const Duration(minutes: 3));

      final body = await response.stream.bytesToString();

      bool success = false;

      if (response.statusCode == 200) {
        try {
          final decoded = jsonDecode(body);
          success = decoded is Map && decoded['ok'] == true;
        } catch (_) {}
      }

      await _setTelegramState(
        file,
        success ? 'sent' : 'failed',
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Video sent to Telegram.'
                : 'Telegram send failed (${response.statusCode}).',
          ),
        ),
      );
    } catch (e) {
      await _setTelegramState(file, 'failed');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Telegram failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => workingFile = null);
      }
    }
  }

  Future<void> _play(File file) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoScreen(file: file),
      ),
    );
  }

  Widget _status(String state) {
    switch (state) {
      case 'sent':
        return const Chip(
          avatar: Icon(Icons.check_circle, size: 18),
          label: Text('Sent'),
        );
      case 'failed':
        return const Chip(
          avatar: Icon(Icons.error, size: 18),
          label: Text('Failed'),
        );
      case 'sending':
        return const Chip(
          avatar: SizedBox(
            width: 15,
            height: 15,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          label: Text('Sending'),
        );
      default:
        return const Chip(
          avatar: Icon(Icons.schedule, size: 18),
          label: Text('Pending'),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Recordings (${files.length})'),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : files.isEmpty
              ? const Center(
                  child: Text(
                    'No recordings yet.',
                    style: TextStyle(fontSize: 18),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: files.length,
                  separatorBuilder: (_, __) => const Divider(),
                  itemBuilder: (context, index) {
                    final file = files[index];

                    return FutureBuilder<String>(
                      future: _telegramState(file),
                      builder: (context, snap) {
                        final state = snap.data ?? 'pending';
                        final busy = workingFile == file.path;

                        return ListTile(
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 5),
                          leading: IconButton.filledTonal(
                            onPressed: () => _play(file),
                            icon: const Icon(Icons.play_arrow),
                          ),
                          title: Text(_name(file)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                file.lastModifiedSync().toLocal().toString(),
                              ),
                              const SizedBox(height: 4),
                              _status(state),
                            ],
                          ),
                          trailing: Wrap(
                            spacing: 2,
                            children: [
                              IconButton(
                                tooltip: 'Send / Retry',
                                onPressed: busy ? null : () => _send(file),
                                icon: const Icon(Icons.telegram),
                              ),
                              IconButton(
                                tooltip: 'Delete',
                                onPressed: busy ? null : () => _delete(file),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
    );
  }
}

class VideoScreen extends StatefulWidget {
  final File file;

  const VideoScreen({
    super.key,
    required this.file,
  });

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  late VideoPlayerController controller;
  bool ready = false;

  @override
  void initState() {
    super.initState();

    controller = VideoPlayerController.file(widget.file);

    controller.initialize().then((_) {
      if (!mounted) return;

      setState(() => ready = true);
      controller.play();
    });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recording'),
      ),
      body: Center(
        child: ready
            ? AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              )
            : const CircularProgressIndicator(),
      ),
      floatingActionButton: ready
          ? FloatingActionButton(
              onPressed: () {
                setState(() {
                  controller.value.isPlaying
                      ? controller.pause()
                      : controller.play();
                });
              },
              child: Icon(
                controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
            )
          : null,
    );
  }
}
