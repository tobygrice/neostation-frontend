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
  /// [systemDefaults] is [LaunchEmulatorResolver.resolve]'s memo, for a pass
  /// over many games.
  static Future<RommSaveLocation> resolve(
    GameModel game,
    SystemModel? system, {
    Map<String, Future<LaunchEmulator>>? systemDefaults,
  }) async {
    if (system == null) return const RetroArchSaveLocation([]);
    final folders = await NeoSyncSaveFolderRepository.getFoldersForSystem(
      system.folderName,
    );
    final emulator = (await LaunchEmulatorResolver.resolve(
      system,
      game,
      systemDefaults: systemDefaults,
    )).uniqueId;
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
  bool isInStandaloneFolder(String filePath) => standaloneFolders.any(
    (root) => path.equals(root, filePath) || path.isWithin(root, filePath),
  );
}

/// A standalone emulator with a Standalone Save Folder on this device.
final class StandaloneSaveLocation extends RommSaveLocation {
  final String emulator;
  final String root;
  final SaveFilePatterns patterns;

  const StandaloneSaveLocation({
    required this.emulator,
    required this.root,
    required this.patterns,
  });

  /// The files in the folder whose names start with [romName], however deep,
  /// each tagged `saves/` or `states/` by [patterns]. Files the patterns
  /// claim for neither are left out.
  ///
  /// Only a prefix is checked here, case-insensitively, to keep the walk cheap
  /// on a large folder; the caller applies the full name rule.
  Future<List<LocalSaveFile>> list(String romName, String gameName) async {
    final paths = await listSaveFilePaths([root], namePrefix: romName);
    final found = <LocalSaveFile>[];
    for (final filePath in paths) {
      final kind = patterns.classify(path.basename(filePath));
      if (kind == null) continue;
      final stat = await File(filePath).stat();
      final relative = path
          .relative(filePath, from: root)
          .replaceAll('\\', '/');
      found.add(
        LocalSaveFile(
          filePath: filePath,
          fileName: path.basename(filePath),
          fileSize: stat.size,
          lastModified: stat.modified,
          gameName: gameName,
          isSynced: false,
          relativePath: '${kind.root}/$relative',
        ),
      );
    }
    return found;
  }

  /// Where a RomM Asset named [localName] goes: over the local file of the same
  /// kind and name when there is one, otherwise beside the game's other files
  /// of that kind, otherwise at the folder root. Null when the result would
  /// leave the folder.
  String? targetFor(
    String localName, {
    required SaveFileKind kind,
    required List<LocalSaveFile> localFiles,
  }) {
    final prefix = '${kind.root}/';
    final sameKind = localFiles.where((f) => f.relativePath.startsWith(prefix));
    for (final f in sameKind) {
      if (path.basename(f.filePath) == localName) return f.filePath;
    }
    final dir = sameKind.isEmpty ? root : path.dirname(sameKind.first.filePath);
    final target = safeJoin(dir, localName);
    if (target == null) return null;
    return path.isWithin(root, target) ? target : null;
  }
}

/// A standalone emulator with no Standalone Save Folder for the system on this
/// device. Nothing syncs, and the game says why.
final class UnconfiguredSaveLocation extends RommSaveLocation {
  final String emulator;

  const UnconfiguredSaveLocation(this.emulator);
}
