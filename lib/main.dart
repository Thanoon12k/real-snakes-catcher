import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'recordings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(NightGuard(cameras: await availableCameras()));
}

class NightGuard extends StatelessWidget {
  final List<CameraDescription> cameras;
  const NightGuard({super.key, required this.cameras});
  @override
  Widget build(BuildContext context) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: GuardPage(cameras: cameras));
}

class GuardPage extends StatefulWidget {
  final List<CameraDescription> cameras;
  const GuardPage({super.key, required this.cameras});
  @override
  State<GuardPage> createState() => _GuardPageState();
}

class _GuardPageState extends State<GuardPage> {
  CameraController? c;
  bool armed = false,
      recording = false,
      busy = false,
      sending = false,
      telegramEnabled = false;
  double sensitivity = .13, lastMotion = 0;
  int seconds = 60, clips = 0;
  List<int>? previous;
  DateTime? lastAnalysis;
  String status = 'جاهز', botToken = '', chatId = '', cameraMode = 'day';
  @override
  void initState() {
    super.initState();
    _load();
    _init();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      botToken = p.getString('botToken') ?? '';
      chatId = p.getString('chatId') ?? '';
      telegramEnabled = p.getBool('telegramEnabled') ?? false;
      sensitivity = p.getDouble('sensitivity') ?? .13;
      seconds = p.getInt('seconds') ?? 60;
      cameraMode = p.getString('cameraMode') ?? 'day';
    });
  }

  Future<void> _init() async {
    if (widget.cameras.isEmpty) {
      setState(() => status = 'لا توجد كاميرا');
      return;
    }
    await [Permission.camera, Permission.microphone].request();
    final back = widget.cameras.firstWhere(
        (x) => x.lensDirection == CameraLensDirection.back,
        orElse: () => widget.cameras.first);
    c = CameraController(back, ResolutionPreset.medium,
        enableAudio: true, imageFormatGroup: ImageFormatGroup.yuv420);
    await c!.initialize();
    if (mounted) setState(() => status = 'اضغط بدء المراقبة');
  }

  Future<void> toggle() async => armed ? stop() : start();
  Future<void> start() async {
    if (c == null || !c!.value.isInitialized) return;
    await WakelockPlus.enable();
    previous = null;
    armed = true;
    setState(() => status = 'مراقبة الحركة...');
    await c!.startImageStream(_frame);
  }

  Future<void> stop() async {
    armed = false;
    if (c?.value.isStreamingImages == true) await c!.stopImageStream();
    await WakelockPlus.disable();
    if (mounted) setState(() => status = 'متوقف');
  }

  void _frame(CameraImage img) {
    if (!armed || recording || busy) return;
    final now = DateTime.now();
    if (lastAnalysis != null &&
        now.difference(lastAnalysis!).inMilliseconds < 350) return;
    lastAnalysis = now;
    busy = true;
    try {
      final y = img.planes[0].bytes, cur = <int>[];
      final step = math.max(1, y.length ~/ 900);
      for (int i = 0; i < y.length && cur.length < 900; i += step)
        cur.add(y[i]);
      if (previous != null && previous!.length == cur.length) {
        double sum = 0;
        for (int i = 0; i < cur.length; i++)
          sum += (cur[i] - previous![i]).abs();
        lastMotion = sum / (cur.length * 255);
        if (cameraMode == 'night')
          lastMotion = math.min(1.0, lastMotion * 1.35);
        if (mounted) setState(() {});
        if (lastMotion > sensitivity) Future.microtask(_trigger);
      }
      previous = cur;
    } finally {
      busy = false;
    }
  }

  Future<void> _trigger() async {
    if (recording || !armed || c == null) return;
    recording = true;
    File? saved;
    try {
      if (c!.value.isStreamingImages) await c!.stopImageStream();
      await _sendMotionAlert();
      await c!.startVideoRecording();
      if (mounted)
        setState(() => status = 'تم اكتشاف حركة — تسجيل $seconds ثانية');
      await Future.delayed(Duration(seconds: seconds));
      if (!c!.value.isRecordingVideo) return;
      final x = await c!.stopVideoRecording();
      final dir = await getApplicationDocumentsDirectory(),
          folder = Directory('${dir.path}/NightGuard');
      if (!await folder.exists()) await folder.create(recursive: true);
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      saved = await File(x.path).copy('${folder.path}/motion_$stamp.mp4');
      clips++;
      if (telegramEnabled &&
          botToken.trim().isNotEmpty &&
          chatId.trim().isNotEmpty) await _sendTelegram(saved);
    } catch (e) {
      if (mounted) setState(() => status = 'خطأ: $e');
    } finally {
      recording = false;
      previous = null;
      if (armed) {
        await Future.delayed(const Duration(milliseconds: 500));
        await c!.startImageStream(_frame);
        if (mounted)
          setState(() => status = 'مراقبة الحركة... ($clips تسجيلات)');
      }
    }
  }

  Future<void> _sendMotionAlert() async {
    if (!telegramEnabled || botToken.trim().isEmpty || chatId.trim().isEmpty) {
      return;
    }

    try {
      final response = await http.post(
        Uri.parse(
          'https://api.telegram.org/bot${botToken.trim()}/sendMessage',
        ),
        body: {
          'chat_id': chatId.trim(),
          'text':
              '🚨 Night Guard\nMotion detected!\n🕐 ${DateTime.now().toLocal()}\n🎥 Recording is starting now...',
        },
      ).timeout(const Duration(seconds: 10));

      debugPrint(
        'Instant Telegram alert: ${response.statusCode}',
      );
    } catch (e) {
      debugPrint('Instant Telegram alert failed: $e');
    }
  }

  Future<bool> _sendTelegram(File f) async {
    sending = true;
    if (mounted) setState(() => status = 'إرسال الفيديو إلى Telegram...');
    try {
      final uri =
          Uri.parse('https://api.telegram.org/bot${botToken.trim()}/sendVideo');
      final r = http.MultipartRequest('POST', uri)
        ..fields['chat_id'] = chatId.trim()
        ..fields['caption'] =
            '🚨 Night Guard: تم اكتشاف حركة\n🕐 ${DateTime.now().toLocal()}\n🎥 $seconds ثانية'
        ..files.add(await http.MultipartFile.fromPath('video', f.path));
      final res = await r.send().timeout(const Duration(minutes: 3));
      final body = await res.stream.bytesToString();
      if (res.statusCode == 200 && ((jsonDecode(body) as Map)['ok'] == true)) {
        final p = await SharedPreferences.getInstance();
        await p.setString(
            'telegram_' + f.path.split(Platform.pathSeparator).last, 'sent');
        return true;
      } else {
        final p = await SharedPreferences.getInstance();
        await p.setString(
            'telegram_' + f.path.split(Platform.pathSeparator).last, 'failed');
      }
      if (mounted)
        setState(() =>
            status = 'حُفظ الفيديو، لكن فشل Telegram (${res.statusCode})');
      return false;
    } catch (_) {
      if (mounted)
        setState(() => status = 'حُفظ الفيديو، لكن تعذر إرساله إلى Telegram');
      return false;
    } finally {
      sending = false;
    }
  }

  Future<void> _settings() async {
    if (armed) return;
    final token = TextEditingController(text: botToken),
        chat = TextEditingController(text: chatId);
    bool enabled = telegramEnabled;
    await showDialog(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
                    title: const Text('إعدادات Telegram'),
                    content: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      DropdownButtonFormField<String>(
                          value: cameraMode,
                          decoration:
                              const InputDecoration(labelText: 'وضع التصوير'),
                          items: const [
                            DropdownMenuItem(
                                value: 'day',
                                child: Text('☀️ نهاري (الافتراضي)')),
                            DropdownMenuItem(
                                value: 'night', child: Text('🌙 ليلي'))
                          ],
                          onChanged: (v) {
                            if (v != null) setD(() => cameraMode = v);
                          }),
                      const SizedBox(height: 10),
                      SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('إرسال المقاطع تلقائياً'),
                          value: enabled,
                          onChanged: (v) => setD(() => enabled = v)),
                      TextField(
                          controller: token,
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                              labelText: 'Bot Token',
                              hintText: '123456:ABC...')),
                      const SizedBox(height: 12),
                      TextField(
                          controller: chat,
                          keyboardType: TextInputType.text,
                          decoration: const InputDecoration(
                              labelText: 'Chat ID',
                              hintText: 'مثال: 123456789 أو -100...')),
                      const SizedBox(height: 12),
                      const Text(
                          'أنشئ البوت عبر BotFather، أرسل له رسالة أولاً، ثم أدخل Token وChat ID هنا. البيانات تبقى على هذا الهاتف.',
                          style: TextStyle(fontSize: 12, color: Colors.white70))
                    ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('إلغاء')),
                      FilledButton(
                          onPressed: () async {
                            botToken = token.text.trim();
                            chatId = chat.text.trim();
                            telegramEnabled = enabled;
                            final p = await SharedPreferences.getInstance();
                            await p.setString('botToken', botToken);
                            await p.setString('chatId', chatId);
                            await p.setBool('telegramEnabled', telegramEnabled);
                            await p.setString('cameraMode', cameraMode);
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted) setState(() {});
                          },
                          child: const Text('حفظ'))
                    ])));
  }

  Future<void> _testTelegram() async {
    if (botToken.isEmpty || chatId.isEmpty) {
      setState(() => status = 'أدخل Bot Token و Chat ID أولاً');
      return;
    }
    try {
      setState(() => status = 'اختبار Telegram...');
      final r = await http.post(
          Uri.parse(
              'https://api.telegram.org/bot${botToken.trim()}/sendMessage'),
          body: {
            'chat_id': chatId.trim(),
            'text': '✅ Night Guard متصل بنجاح'
          }).timeout(const Duration(seconds: 20));
      setState(() => status = r.statusCode == 200
          ? 'تم إرسال رسالة الاختبار ✓'
          : 'فشل الاختبار (${r.statusCode})');
    } catch (e) {
      setState(() => status = 'فشل اختبار Telegram');
    }
  }

  @override
  void dispose() {
    armed = false;
    c?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = c?.value.isInitialized == true;
    return Scaffold(
        appBar:
            AppBar(title: const Text('Night Guard — حارس الغرفة'), actions: [
          IconButton(
              onPressed: armed
                  ? null
                  : () {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => RecordingsPage(
                                  botToken: botToken,
                                  chatId: chatId,
                                  telegramEnabled: telegramEnabled)));
                    },
              icon: const Icon(Icons.video_library),
              tooltip: 'Recordings'),
          IconButton(
              onPressed: armed ? null : _settings,
              icon: const Icon(Icons.settings),
              tooltip: 'الإعدادات')
        ]),
        body: SafeArea(
            child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(children: [
                  Expanded(
                      child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Container(
                              color: Colors.black,
                              child: ready
                                  ? Center(child: CameraPreview(c!))
                                  : const Center(
                                      child: CircularProgressIndicator())))),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: Text(status)),
                    Text('حركة ${(lastMotion * 100).toStringAsFixed(1)}%')
                  ]),
                  Row(children: [
                    const Text('الحساسية'),
                    Expanded(
                        child: Slider(
                            value: sensitivity,
                            min: .005,
                            max: .30,
                            divisions: 59,
                            onChanged: armed
                                ? null
                                : (v) async {
                                    setState(() => sensitivity = v);
                                    (await SharedPreferences.getInstance())
                                        .setDouble('sensitivity', v);
                                  })),
                    Text('${(sensitivity * 100).round()}%')
                  ]),
                  Row(children: [
                    const Text('مدة التسجيل'),
                    const SizedBox(width: 10),
                    DropdownButton<int>(
                        value: seconds,
                        onChanged: armed
                            ? null
                            : (v) async {
                                setState(() => seconds = v!);
                                (await SharedPreferences.getInstance())
                                    .setInt('seconds', v!);
                              },
                        items: [30, 60, 90, 120]
                            .map((v) => DropdownMenuItem(
                                value: v, child: Text('$v ثانية')))
                            .toList()),
                    Text(cameraMode == 'day' ? '☀️ نهاري' : '🌙 ليلي'),
                    const Spacer(),
                    Icon(
                        telegramEnabled
                            ? Icons.telegram
                            : Icons.telegram_outlined,
                        size: 18),
                    const SizedBox(width: 4),
                    Text(telegramEnabled ? 'Telegram مفعّل' : 'Telegram متوقف')
                  ]),
                  if (!armed && telegramEnabled)
                    Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                            onPressed: sending ? null : _testTelegram,
                            icon: const Icon(Icons.send),
                            label: const Text('اختبار Telegram'))),
                  const SizedBox(height: 6),
                  SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: FilledButton.icon(
                          onPressed: ready && !recording ? toggle : null,
                          icon: Icon(armed ? Icons.stop : Icons.visibility),
                          label:
                              Text(armed ? 'إيقاف المراقبة' : 'بدء المراقبة'))),
                  const SizedBox(height: 7),
                  const Text(
                      'كل فيديو يُحفظ محلياً أولاً. عند تفعيل Telegram يُرسل تلقائياً بعد انتهاء التسجيل.',
                      style: TextStyle(fontSize: 12, color: Colors.white70))
                ]))));
  }
}
