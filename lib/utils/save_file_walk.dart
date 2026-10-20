import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path;

/// Files over this size are never saves. It also keeps a save folder that
/// holds ROMs from hashing disc images.
const int maxSaveFileSize = 10 * 1024 * 1024;

/// Every file under [folders], however deep, that could be a save, walked off
/// the UI isolate. NeoSync recovery backups (`*.neosync.bak`) and files over
/// [maxSaveFileSize] are left out.
///
/// With [namePrefix], only files whose names start with it, ignoring case, are
/// kept, which spares the caller statting the rest of a large folder.
Future<List<String>> listSaveFilePaths(
  List<String> folders, {
  String namePrefix = '',
}) {
  final prefix = namePrefix.toLowerCase();
  return Isolate.run(() {
    // A file that cannot be statted (a dangling link) is no save.
    bool small(File file) {
      try {
        return file.lengthSync() <= maxSaveFileSize;
      } catch (_) {
        return false;
      }
    }

    final paths = <String>[];
    for (final folderPath in folders) {
      final dir = Directory(folderPath);
      if (!dir.existsSync()) continue;
      for (final file in dir.listSync(recursive: true).whereType<File>()) {
        final lower = file.path.toLowerCase();
        if (lower.endsWith('.neosync.bak')) continue;
        if (!path.basename(lower).startsWith(prefix)) continue;
        if (small(file)) paths.add(file.path);
      }
    }
    return paths;
  });
}
