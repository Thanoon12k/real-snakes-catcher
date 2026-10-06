import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:video_player/video_player.dart';

import 'clips.dart';
import 'telegram_bot.dart';

class RecordingsPage extends StatefulWidget {
  final TelegramBot bot;

  /// Id of the clip being recorded right now (not playable yet).
  final String? Function() recordingId;
  const RecordingsPage(
      {super.key, required this.bot, required this.recordingId});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  List<File> files = [];
  bool loading = true;
  String? working;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await Clips.list();
    if (!mounted) return;
    setState(() {
      files = result;
      loading = false;
    });
  }

  void _toast(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _delete(File file) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete recording?'),
        content: const Text('The copy in the phone gallery is kept.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      _toast('Delete failed: $e');
    }
    await _load();
  }

  Future<void> _saveToGallery(File file) async {
    try {
      await Gal.putVideo(file.path, album: Clips.galleryAlbum);
      _toast('Saved to Gallery → ${Clips.galleryAlbum}');
    } catch (e) {
      _toast('Could not save to gallery: $e');
    }
  }

  Future<void> _send(File file) async {
    final bot = widget.bot;
    if (!bot.ready || bot.recipients.isEmpty) {
      _toast('Set up Telegram and add subscribers first.');
      return;
    }
    final id = Clips.idOf(file)!;
    setState(() => working = file.path);
    int sent = 0;
    for (final chat in bot.recipients) {
      if (await bot.sendVideoTo(chat, id)) sent++;
    }
    if (!mounted) return;
    setState(() => working = null);
    _toast(sent > 0
        ? 'Video sent to $sent chat(s).'
        : 'Send failed: ${bot.lastError}');
  }

  @override
  Widget build(BuildContext context) {
    final recId = widget.recordingId();
    return Scaffold(
      appBar: AppBar(
        title: Text('Recordings (${files.length})'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh))
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : files.isEmpty
              ? const Center(
                  child: Text('No recordings yet.',
                      style: TextStyle(fontSize: 18)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: files.length,
                    separatorBuilder: (_, __) => const Divider(),
                    itemBuilder: (context, i) {
                      final file = files[i];
                      final id = Clips.idOf(file)!;
                      final live = id == recId;
                      final busy = working == file.path;
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(vertical: 4),
                        leading: IconButton.filledTonal(
                          onPressed: live
                              ? null
                              : () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => VideoScreen(file: file))),
                          icon: const Icon(Icons.play_arrow),
                        ),
                        title: Text(id),
                        subtitle: Text(live
                            ? '🔴 recording…'
                            : '${file.lastModifiedSync().toLocal().toString().substring(0, 19)}'
                                '  •  ${Clips.sizeText(file.lengthSync())}'),
                        trailing: busy
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : PopupMenuButton<String>(
                                enabled: !live,
                                onSelected: (v) {
                                  if (v == 'send') _send(file);
                                  if (v == 'gallery') _saveToGallery(file);
                                  if (v == 'delete') _delete(file);
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                      value: 'send',
                                      child: Text('Send to all subscribers')),
                                  PopupMenuItem(
                                      value: 'gallery',
                                      child: Text('Save to gallery again')),
                                  PopupMenuItem(
                                      value: 'delete', child: Text('Delete')),
                                ],
                              ),
                      );
                    },
                  ),
                ),
    );
  }
}

class VideoScreen extends StatefulWidget {
  final File file;
  const VideoScreen({super.key, required this.file});

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  late final VideoPlayerController controller =
      VideoPlayerController.file(widget.file);
  String? error;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChange);
    controller.initialize().then((_) {
      if (mounted) controller.play();
    }).catchError((Object e) {
      if (mounted) setState(() => error = '$e');
    }).timeout(const Duration(seconds: 15), onTimeout: () {
      if (mounted && !controller.value.isInitialized) {
        setState(() => error = 'The video took too long to open.');
      }
    });
  }

  void _onChange() {
    if (!mounted) return;
    if (controller.value.hasError && error == null) {
      error = controller.value.errorDescription ?? 'Playback error';
    }
    setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_onChange);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = controller.value;
    return Scaffold(
      appBar: AppBar(title: Text(Clips.idOf(widget.file) ?? 'Recording')),
      body: Center(
        child: error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                    'Could not play this video here.\n\n$error\n\n'
                    'Try opening it from the phone Gallery → ${Clips.galleryAlbum}.',
                    textAlign: TextAlign.center),
              )
            : v.isInitialized
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    AspectRatio(
                        aspectRatio: v.aspectRatio,
                        child: VideoPlayer(controller)),
                    VideoProgressIndicator(controller,
                        allowScrubbing: true,
                        padding: const EdgeInsets.all(12)),
                  ])
                : const CircularProgressIndicator(),
      ),
      floatingActionButton: v.isInitialized && error == null
          ? FloatingActionButton(
              onPressed: () =>
                  v.isPlaying ? controller.pause() : controller.play(),
              child: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow),
            )
          : null,
    );
  }
}
