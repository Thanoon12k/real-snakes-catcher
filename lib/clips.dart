import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Recordings live in the app's own folder (so the bot can send them on
/// request) and a copy is also saved to the phone gallery.
class Clips {
  static const galleryAlbum = 'Snake Catcher';

  static Future<Directory> folder() async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/SnakeCatcher');
    if (!await folder.exists()) await folder.create(recursive: true);
    return folder;
  }

  /// Event ids look like 20261006_231502 and double as file names.
  static String newId(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  static Future<File> fileFor(String id) async =>
      File('${(await folder()).path}/snake_$id.mp4');

  static String? idOf(File f) {
    final name = f.uri.pathSegments.last;
    if (!name.startsWith('snake_') || !name.endsWith('.mp4')) return null;
    return name.substring(6, name.length - 4);
  }

  /// Newest first.
  static Future<List<File>> list() async {
    final files = (await folder())
        .listSync()
        .whereType<File>()
        .where((f) => idOf(f) != null)
        .toList();
    files.sort((a, b) => idOf(b)!.compareTo(idOf(a)!));
    return files;
  }

  static String sizeText(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(0)} KB';

  static String lengthText(int seconds) =>
      seconds < 60 ? '$seconds s' : '${seconds ~/ 60} min';
}
