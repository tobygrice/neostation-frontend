import 'dart:io';

import 'package:path/path.dart' as path;

import '../models/game_model.dart';
import '../models/neo_sync_models.dart';
import '../models/save_file_patterns.dart';
import '../models/system_model.dart';
import '../repositories/neosync_save_folder_repository.dart';
import '../services/game/launch_emulator_resolver.dart';
import '../services/launcher_service.dart';
import '../utils/safe_path.dart';
import '../utils/save_file_walk.dart';

/// What resolving many games' save locations in one pass can share.
///
/// Each system's default Launch Emulator is resolved once, and each system and
/// emulator's location once, so its Standalone Save Folder is walked once for
/// every game that launches in it rather than once per game. Meant for a
/// single pass: what it remembers goes stale as the folders change.
class RommSaveLocationPass {
  /// [LaunchEmulatorResolver.resolve]'s memo.
  final systemDefaults = <String, Future<LaunchEmulator>>{};

  final _locations = <(String, String?), Future<RommSaveLocation>>{};
}

/// Where a game's saves are on this device under RomM: wherever its Launch
/// Emulator keeps them, and nowhere else.
///
/// Following the Launch Emulator is what keeps sync honest about which copy is
/// live. A RetroArch game ignores stray files in a Standalone Save Folder, a
/// standalone game ignores RetroArch's leftovers, and a game whose standalone
/// emulator has no folder on this device syncs nothing rather than writing
/// where the emulator will never look.
sealed class RommSaveLocation {
  const RommSaveLocation();

  /// The location for [game] on [system], or RetroArch's when either is
  /// unknown, which is how RomM sync behaved before it followed the emulator.
  ///
  /// [pass] shares the work across a pass over many games, and
  /// [installedDefaults] the auto-resolved default emulator across separate
  /// calls (see [LaunchEmulatorResolver.resolve]).
  static Future<RommSaveLocation> resolve(
    GameModel game,
    SystemModel? system, {
    RommSaveLocationPass? pass,
    InstalledDefaultCache? installedDefaults,
  }) async {
    if (system == null) return const RetroArchSaveLocation([]);
    final emulator = (await LaunchEmulatorResolver.resolve(
      system,
      game,
      systemDefaults: pass?.systemDefaults,
      installedDefaults: installedDefaults,
    )).uniqueId;
    if (pass == null) return _forEmulator(system, emulator, shared: false);
    return pass._locations.putIfAbsent((
      system.folderName,
      emulator,
    ), () => _forEmulator(system, emulator, shared: true));
  }

  /// The location of [system]'s saves made by [emulator], [shared] by the
  /// games of a pass.
  static Future<RommSaveLocation> _forEmulator(
    SystemModel system,
    String? emulator, {
    required bool shared,
  }) async {
    final folders = await NeoSyncSaveFolderRepository.getFoldersForSystem(
      system.folderName,
    );
    if (emulator == null ||
        emulator.isEmpty ||
        await LaunchEmulatorResolver.isRetroArchCore(system, emulator)) {
      return RetroArchSaveLocation(folders.values.toList());
    }
    final root = folders[emulator];
    if (root == null || root.isEmpty) {
      return UnconfiguredSaveLocation(emulator);
    }
    return StandaloneSaveLocation(
      emulator: emulator,
      root: root,
      // Read from the system definition, the way launch options are.
      patterns: await LauncherService.instance.loadSaveFilePatterns(
        system.folderName,
        emulator,
      ),
      walkOnce: shared,
    );
  }
}

/// A RetroArch Core: RetroArch's own save and state folders, as resolved
/// before this location existed.
final class RetroArchSaveLocation extends RommSaveLocation {
  /// Every Standalone Save Folder configured for the system. The RetroArch
  /// resolution also reports files from these, and none of them is
  /// RetroArch's.
  final List<String> standaloneFolders;

  const RetroArchSaveLocation(this.standaloneFolders);

  /// Whether [filePath] lies in one of [standaloneFolders].
  bool isInStandaloneFolder(String filePath) =>
      saveFolderContaining(standaloneFolders, filePath) != null;
}

/// A standalone emulator with a Standalone Save Folder on this device.
final class StandaloneSaveLocation extends RommSaveLocation {
  final String emulator;
  final String root;
  final SaveFilePatterns patterns;

  /// Whether [list] walks the whole folder once and answers every game from
  /// that, for a location a pass shares among its games. Otherwise each call
  /// walks it for one game's files, which stats far fewer of a large folder's.
  final bool walkOnce;

  StandaloneSaveLocation({
    required this.emulator,
    required this.root,
    required this.patterns,
    this.walkOnce = false,
  });

  /// Every file in the folder that could be a save, walked at most once for
  /// this location.
  late final Future<List<String>> _allPaths = listSaveFilePaths([root]);

  /// The files in the folder whose names start with [romName], however deep,
  /// each tagged `saves/` or `states/` by [patterns]. Files the patterns
  /// claim for neither are left out.
  ///
  /// Only a prefix is checked here, case-insensitively; the caller applies the
  /// full name rule.
  ///
  /// A RomM Asset is paired with a local file by name alone, so of several
  /// files with the same name in different subfolders only the most recently
  /// modified, the likeliest to be the one the emulator uses, is listed.
  /// Otherwise each would be compared against, and uploaded over, the same
  /// asset.
  Future<List<LocalSaveFile>> list(String romName, String gameName) async {
    final paths = walkOnce
        ? [
            for (final p in await _allPaths)
              if (fileNameStartsWith(p, romName)) p,
          ]
        : await listSaveFilePaths([root], namePrefix: romName);
    final byName = <String, LocalSaveFile>{};
    for (final filePath in paths) {
      final name = path.basename(filePath);
      final kind = patterns.classify(name);
      if (kind == null) continue;
      final stat = await File(filePath).stat();
      final kept = byName[name];
      if (kept != null && !stat.modified.isAfter(kept.lastModified)) continue;
      final relative = path
          .relative(filePath, from: root)
          .replaceAll('\\', '/');
      byName[name] = LocalSaveFile(
        filePath: filePath,
        fileName: name,
        fileSize: stat.size,
        lastModified: stat.modified,
        gameName: gameName,
        isSynced: false,
        relativePath: '${kind.root}/$relative',
      );
    }
    return byName.values.toList();
  }

  /// Where a RomM Asset named [localName] goes: over the local file of the same
  /// kind and name when there is one, otherwise beside the game's other files
  /// of that kind, otherwise beside the folder's other files with its
  /// extension (another game's memory cards, say), otherwise at the folder
  /// root. Null when the result would leave the folder.
  Future<String?> targetFor(
    String localName, {
    required SaveFileKind kind,
    required List<LocalSaveFile> localFiles,
  }) async {
    final prefix = '${kind.root}/';
    final sameKind = localFiles.where((f) => f.relativePath.startsWith(prefix));
    for (final f in sameKind) {
      if (path.basename(f.filePath) == localName) return f.filePath;
    }
    final dir = sameKind.isEmpty
        ? await _dirOfExtension(path.extension(localName)) ?? root
        : path.dirname(sameKind.first.filePath);
    final target = safeJoin(dir, localName);
    if (target == null) return null;
    return path.isWithin(root, target) ? target : null;
  }

  /// The directory in the folder holding the most files with [extension], or
  /// null when none has one.
  Future<String?> _dirOfExtension(String extension) async {
    if (extension.isEmpty) return null;
    final lower = extension.toLowerCase();
    final counts = <String, int>{};
    for (final p in await _allPaths) {
      if (path.extension(p).toLowerCase() != lower) continue;
      final dir = path.dirname(p);
      counts[dir] = (counts[dir] ?? 0) + 1;
    }
    String? best;
    for (final MapEntry(key: dir, value: count) in counts.entries) {
      if (best == null || count > counts[best]!) best = dir;
    }
    return best;
  }
}

/// A standalone emulator with no Standalone Save Folder for the system on this
/// device. Nothing syncs, and the game says why.
final class UnconfiguredSaveLocation extends RommSaveLocation {
  final String emulator;

  const UnconfiguredSaveLocation(this.emulator);
}
