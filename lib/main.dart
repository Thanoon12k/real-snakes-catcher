import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'clips.dart';
import 'motion.dart';
import 'recordings_page.dart';
import 'settings_page.dart';
import 'telegram_bot.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  List<CameraDescription> cameras = [];
  try {
    cameras = await availableCameras();
  } catch (_) {}
  runApp(SnakeCatcherApp(cameras: cameras));
}

class SnakeCatcherApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const SnakeCatcherApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Snake Catcher',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xFF3FAE5A),
        ),
        home: GuardPage(cameras: cameras),
      );
}

class GuardPage extends StatefulWidget {
  final List<CameraDescription> cameras;
  const GuardPage({super.key, required this.cameras});

  @override
  State<GuardPage> createState() => _GuardPageState();
}

class _GuardPageState extends State<GuardPage> {
  static const clipLengths = [5, 10, 30, 60, 120, 180, 300];

  /// A clip keeps extending while motion continues, but never beyond this.
  static const maxClip = Duration(minutes: 5);
  static const analyseEvery = Duration(milliseconds: 300);

  final bot = TelegramBot();
  CameraController? c;

  bool armed = false, recording = false, starting = false;
  double slider = sliderFromThreshold(0.01), lastMotion = 0;
  int clipSeconds = 60, clips = 0, hits = 0;
  String cameraMode = 'day', status = 'Starting camera…';

  Float32List? prevGrid, prevPhotoGrid;
  DateTime lastAnalysis = DateTime(0), lastMotionAt = DateTime(0);

  // Current recording.
  String? recId;
  DateTime? recStart, recEnd, lastRecFrame;
  bool photoFallback = true, analysing = false;
  Timer? ticker;

  double get threshold => thresholdFromSlider(slider);
  bool get ready => c?.value.isInitialized == true;

  @override
  void initState() {
    super.initState();
    bot
      ..isRecording = ((id) => recording && id == recId)
      ..currentRecordingId = (() => recording ? recId : null)
      ..statusText = _statusForBot;
    _start();
  }

  Future<void> _start() async {
    final p = await SharedPreferences.getInstance();
    slider = p.getDouble('slider') ?? slider;
    final saved = p.getInt('clipSeconds') ?? 60;
    clipSeconds = clipLengths.contains(saved) ? saved : 60;
    cameraMode = p.getString('cameraMode') ?? 'day';
    await bot.load();
    bot.restartPolling();
    if (mounted) setState(() {});
    await _initCamera();
  }

  Future<void> _initCamera() async {
    if (widget.cameras.isEmpty) {
      setState(() => status = 'No camera found');
      return;
    }
    await [Permission.camera, Permission.microphone].request();
    try {
      await Gal.requestAccess();
    } catch (_) {}
    final back = widget.cameras.firstWhere(
        (x) => x.lensDirection == CameraLensDirection.back,
        orElse: () => widget.cameras.first);
    c = CameraController(back, ResolutionPreset.medium,
        enableAudio: true, imageFormatGroup: ImageFormatGroup.yuv420);
    try {
      await c!.initialize();
      // Motion checks take photos while recording; never fire the flash.
      await c!.setFlashMode(FlashMode.off).catchError((_) {});
      await c!.startImageStream(_onFrame);
      if (mounted) setState(() => status = 'Ready — press Start guard');
    } catch (e) {
      if (mounted) setState(() => status = 'Camera error: $e');
    }
  }

  // ------------------------------------------------------------ motion

  void _onFrame(CameraImage image) {
    final now = DateTime.now();
    if (recording) lastRecFrame = now;
    if (now.difference(lastAnalysis) < analyseEvery) return;
    lastAnalysis = now;

    final grid = gridFromCameraImage(image);
    final prev = prevGrid;
    prevGrid = grid;
    if (prev == null) return;
    _gotMotionScore(motionScore(prev, grid, noiseFor(cameraMode)));

    if (!armed || recording || starting) return;
    hits = lastMotion > threshold ? hits + 1 : 0;
    // Two motion frames in a row (~0.3 s apart) to ignore single-frame noise.
    if (hits >= 2) {
      hits = 0;
      _startClip(FrameSnapshot.of(image, c!.description.sensorOrientation));
    }
  }

  void _gotMotionScore(double score) {
    lastMotion = score;
    if (score > threshold) {
      lastMotionAt = DateTime.now();
      if (recording) _extendClip();
    }
    if (mounted) setState(() {});
  }

  void _extendClip() {
    final start = recStart, end = recEnd;
    if (start == null || end == null) return;
    final want = DateTime.now().add(Duration(seconds: clipSeconds));
    final cap = start.add(maxClip);
    final newEnd = want.isBefore(cap) ? want : cap;
    if (newEnd.isAfter(end)) recEnd = newEnd;
  }

  /// While recording, most phones cannot also stream frames. On those we
  /// take a silent low-resolution photo every ~1.5 s to keep sensing.
  Future<void> _photoMotionCheck() async {
    if (analysing) return;
    analysing = true;
    try {
      final shot = await c!.takePicture();
      final grid = await compute(gridFromJpegFile, shot.path);
      File(shot.path).delete().ignore();
      if (grid == null) return;
      final prev = prevPhotoGrid;
      prevPhotoGrid = grid;
      if (prev != null) {
        _gotMotionScore(motionScore(prev, grid, noiseFor(cameraMode)));
      }
    } catch (e) {
      // This phone cannot take photos while recording; clips will use
      // their set length without extending.
      photoFallback = false;
      debugPrint('Photo motion check unavailable: $e');
    } finally {
      analysing = false;
    }
  }

  // ---------------------------------------------------------- recording

  Future<void> _startClip(FrameSnapshot frame) async {
    starting = true;
    final id = Clips.newId(DateTime.now());
    try {
      if (c!.value.isStreamingImages) await c!.stopImageStream();
      await c!.startVideoRecording(onAvailable: _onFrame);
      recId = id;
      recStart = DateTime.now();
      recEnd = recStart!.add(Duration(seconds: clipSeconds));
      lastRecFrame = null;
      prevGrid = null;
      prevPhotoGrid = null;
      recording = true;
      ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      if (mounted) setState(() => status = 'Motion detected — recording');
      unawaited(_sendAlert(id, frame));
      unawaited(_recordLoop());
    } catch (e) {
      if (mounted) setState(() => status = 'Could not start recording: $e');
      await _resumeStream();
    } finally {
      starting = false;
    }
  }

  Future<void> _sendAlert(String id, FrameSnapshot frame) async {
    if (!bot.ready || bot.recipients.isEmpty) return;
    Uint8List? jpeg;
    try {
      jpeg = await compute(frameToJpeg, frame);
    } catch (e) {
      debugPrint('Snapshot failed: $e');
    }
    final sent = await bot.sendMotionAlert(id, jpeg);
    if (mounted && sent == 0) {
      setState(() => status = 'Telegram alert failed: ${bot.lastError}');
    }
  }

  Future<void> _recordLoop() async {
    DateTime lastPhoto = DateTime.now();
    while (true) {
      await Future.delayed(const Duration(milliseconds: 250));
      final now = DateTime.now();
      if (!armed || !recording || now.isAfter(recEnd!)) break;
      final streaming = lastRecFrame != null &&
          now.difference(lastRecFrame!) < const Duration(seconds: 2);
      final settled = now.difference(recStart!) > const Duration(seconds: 2);
      if (!streaming &&
          settled &&
          photoFallback &&
          now.difference(lastPhoto) > const Duration(milliseconds: 1500)) {
        lastPhoto = now;
        await _photoMotionCheck();
      }
    }
    await _finishClip();
  }

  Future<void> _finishClip() async {
    final id = recId!;
    ticker?.cancel();
    try {
      final x = await c!.stopVideoRecording();
      final dest = await Clips.fileFor(id);
      try {
        await File(x.path).rename(dest.path);
      } catch (_) {
        await File(x.path).copy(dest.path);
        await File(x.path).delete();
      }
      clips++;
      recording = false;
      try {
        await Gal.putVideo(dest.path, album: Clips.galleryAlbum);
        status = 'Saved clip $clips to Gallery → ${Clips.galleryAlbum}';
      } catch (e) {
        status = 'Saved in app (gallery failed: $e)';
      }
      unawaited(bot.clipReady(id));
    } catch (e) {
      status = 'Recording error: $e';
    } finally {
      recording = false;
      recId = null;
      recStart = recEnd = null;
      await _resumeStream();
      if (!armed) await WakelockPlus.disable();
      if (mounted) setState(() {});
    }
  }

  Future<void> _resumeStream() async {
    prevGrid = null;
    hits = 0;
    if (c == null || !ready || c!.value.isStreamingImages) return;
    try {
      await c!.startImageStream(_onFrame);
    } catch (e) {
      debugPrint('Could not restart image stream: $e');
    }
  }

  // --------------------------------------------------------------- guard

  Future<void> _toggle() async {
    if (armed) {
      // Any running clip is finished and saved by the record loop.
      setState(() {
        armed = false;
        status = recording ? 'Stopping — saving clip…' : 'Guard stopped';
      });
      if (!recording) await WakelockPlus.disable();
    } else {
      await WakelockPlus.enable();
      hits = 0;
      setState(() {
        armed = true;
        status = 'Watching for motion…';
      });
    }
  }

  String _statusForBot() => armed
      ? '🟢 Guard is ON${recording ? ' — 🔴 recording now' : ''}.\n'
          'Clips this session: $clips'
      : '⚪ Guard is OFF.';

  Future<void> _openSettings() async {
    final mode = await Navigator.push<String>(
        context,
        MaterialPageRoute(
            builder: (_) => SettingsPage(bot: bot, cameraMode: cameraMode)));
    if (mode != null && mounted) setState(() => cameraMode = mode);
  }

  @override
  void dispose() {
    armed = false;
    ticker?.cancel();
    bot.stopPolling();
    c?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final elapsed =
        recStart == null ? 0 : DateTime.now().difference(recStart!).inSeconds;
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Image(image: AssetImage('assets/icon.png'), width: 30, height: 30),
          SizedBox(width: 10),
          Text('Snake Catcher'),
        ]),
        actions: [
          IconButton(
            tooltip: 'Recordings',
            icon: const Icon(Icons.video_library),
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => RecordingsPage(
                        bot: bot,
                        recordingId: () => recording ? recId : null))),
          ),
          IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings),
              onPressed: _openSettings),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  color: Colors.black,
                  child: Stack(fit: StackFit.expand, children: [
                    ready
                        ? Center(child: CameraPreview(c!))
                        : const Center(child: CircularProgressIndicator()),
                    if (recording)
                      Positioned(
                          top: 12,
                          left: 12,
                          child: _RecBadge(seconds: elapsed)),
                    if (armed && !recording)
                      const Positioned(
                        top: 12,
                        left: 12,
                        child:
                            _Pill(color: Color(0xCC2E7D32), text: '● GUARDING'),
                      ),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: Text(status,
                      maxLines: 2, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Text('Motion ${percent(lastMotion)}',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: lastMotion > threshold ? Colors.redAccent : null)),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: lastMotion <= 0 ? 0 : sliderFromThreshold(lastMotion),
                minHeight: 6,
                color: lastMotion > threshold ? Colors.redAccent : Colors.green,
              ),
            ),
            Row(children: [
              const Text('Trigger at'),
              Expanded(
                child: Slider(
                  value: slider,
                  onChanged: (v) => setState(() => slider = v),
                  onChangeEnd: (v) async =>
                      (await SharedPreferences.getInstance())
                          .setDouble('slider', v),
                ),
              ),
              SizedBox(
                  width: 56,
                  child: Text(percent(threshold), textAlign: TextAlign.end)),
            ]),
            Row(children: [
              const Text('Clip length'),
              const SizedBox(width: 10),
              DropdownButton<int>(
                value: clipSeconds,
                onChanged: (v) async {
                  setState(() => clipSeconds = v!);
                  (await SharedPreferences.getInstance())
                      .setInt('clipSeconds', v!);
                },
                items: [
                  for (final s in clipLengths)
                    DropdownMenuItem(value: s, child: Text(Clips.lengthText(s)))
                ],
              ),
              const SizedBox(width: 8),
              Icon(cameraMode == 'day' ? Icons.wb_sunny : Icons.nightlight,
                  size: 18),
              const Spacer(),
              Icon(Icons.telegram,
                  size: 18,
                  color: bot.ready ? Colors.lightBlueAccent : Colors.white38),
              const SizedBox(width: 4),
              Text(bot.ready
                  ? '${bot.recipients.length} subscribed'
                  : 'Telegram off'),
            ]),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: FilledButton.icon(
                style: armed
                    ? FilledButton.styleFrom(
                        backgroundColor: Colors.red.shade700)
                    : null,
                onPressed: ready ? _toggle : null,
                icon: Icon(armed ? Icons.stop : Icons.visibility),
                label: Text(armed ? 'Stop guard' : 'Start guard'),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Clips keep recording while motion continues (max 5 min) and are saved to '
              'Gallery → ${Clips.galleryAlbum}. Telegram gets the first photo; '
              'subscribers tap "Get full video" to receive the clip.',
              style: TextStyle(fontSize: 11, color: Colors.white60),
              textAlign: TextAlign.center,
            ),
          ]),
        ),
      ),
    );
  }
}

class _RecBadge extends StatefulWidget {
  final int seconds;
  const _RecBadge({required this.seconds});

  @override
  State<_RecBadge> createState() => _RecBadgeState();
}

class _RecBadgeState extends State<_RecBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController blink = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 700))
    ..repeat(reverse: true);

  @override
  void dispose() {
    blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.seconds ~/ 60, s = widget.seconds % 60;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
          color: Colors.black54, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        FadeTransition(
          opacity: blink,
          child: const Icon(Icons.circle, color: Colors.red, size: 14),
        ),
        const SizedBox(width: 6),
        Text('REC $m:${s.toString().padLeft(2, '0')}',
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  final Color color;
  final String text;
  const _Pill({required this.color, required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(20)),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12)),
      );
}
