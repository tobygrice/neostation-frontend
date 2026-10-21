import 'package:flutter/foundation.dart';

import '../../models/core_emulator_model.dart';
import '../../models/game_model.dart';
import '../../models/system_model.dart';
import '../../repositories/emulator_repository.dart';
import '../../utils/emulator_loader.dart';

/// The emulator this device would start a game with, and how it was chosen.
class LaunchEmulator {
  /// The emulator's unique id, or null when nothing could be resolved.
  final String? uniqueId;

  /// How [uniqueId] was chosen, for the launch log.
  final String source;

  /// Whether the user chose it (a per-game override or a system default they
  /// set), as opposed to one picked for them. Only a choice the user made is
  /// worth failing a launch over.
  final bool isExplicit;

  const LaunchEmulator(this.uniqueId, this.source, {required this.isExplicit});
}

/// Resolves the Launch Emulator: the game's own emulator choice, then the
/// user-selected system default, then the auto-resolved default installed
/// emulator.
///
/// Launch and save sync both ask here, so the emulator a game starts in and
/// the emulator whose saves are synced for it can never disagree.
class LaunchEmulatorResolver {
  LaunchEmulatorResolver._();

  /// The Launch Emulator for [game] on [system].
  ///
  /// [systemDefaults] memoises the system-level answer by system id, for a
  /// caller resolving many games in one pass: on Android the auto-resolved
  /// default asks the platform whether each emulator is installed.
  ///
  /// [installedDefaults] remembers just that auto-resolved default for a
  /// while, for a caller resolving one game at a time. A launch passes
  /// neither: it always asks afresh.
  static Future<LaunchEmulator> resolve(
    SystemModel system,
    GameModel game, {
    Map<String, Future<LaunchEmulator>>? systemDefaults,
    InstalledDefaultCache? installedDefaults,
  }) {
    final perGame = game.emulatorName;
    if (perGame != null) {
      return Future.value(
        LaunchEmulator(perGame, 'per-game override', isExplicit: true),
      );
    }
    final systemId = system.id;
    if (systemDefaults == null || systemId == null) {
      return _systemDefault(system, installedDefaults);
    }
    return systemDefaults.putIfAbsent(
      systemId,
      () => _systemDefault(system, installedDefaults),
    );
  }

  /// The emulator [system]'s games launch in when they choose none.
  static Future<LaunchEmulator> _systemDefault(
    SystemModel system,
    InstalledDefaultCache? installedDefaults,
  ) async {
    final systemId = system.id;
    if (systemId == null) {
      return const LaunchEmulator(null, 'none', isExplicit: false);
    }
    final userDefault =
        await EmulatorRepository.getUserDefaultEmulatorForSystem(systemId);
    if (userDefault != null) {
      return LaunchEmulator(
        userDefault.uniqueId,
        'system default (user-selected)',
        isExplicit: true,
      );
    }
    final defaultEmu = installedDefaults == null
        ? await _resolveDefaultInstalledEmulator(system)
        : await installedDefaults._get(
            systemId,
            () => _resolveDefaultInstalledEmulator(system),
          );
    if (defaultEmu != null) {
      return LaunchEmulator(
        defaultEmu.uniqueId,
        'auto-resolved default',
        isExplicit: false,
      );
    }
    return const LaunchEmulator(null, 'none', isExplicit: false);
  }

  /// Whether [uniqueId] is a RetroArch Core on this device.
  ///
  /// Decided by the emulator's own row, by [CoreEmulatorModel.isRetroArchCore],
  /// the same test Standalone Save Folders uses to leave cores out. An id with
  /// no row on this device falls back to the `.ra.`/`.ra32.`/`.ra64.` naming
  /// the system definitions follow.
  static Future<bool> isRetroArchCore(
    SystemModel system,
    String uniqueId,
  ) async {
    final systemId = system.id;
    if (systemId != null) {
      final emulators = await EmulatorRepository.getEmulatorsForSystemCurrentOs(
        systemId,
      );
      for (final e in emulators) {
        if (e.uniqueId == uniqueId) return e.isRetroArchCore;
      }
    }
    return CoreEmulatorModel.hasRetroArchCoreId(uniqueId);
  }

  /// Resolves which emulator to auto-select when a game has no per-game
  /// override.
  ///
  /// [EmulatorRepository.getDefaultEmulatorForSystem] returns the *configured*
  /// default, which for many systems is a RetroArch core flagged `is_default`.
  /// That core is frequently not actually installed (the RetroArch app is
  /// present but the specific libretro core isn't), so auto-selecting it yields
  /// a generic "Launch error" on a normal launch (issue #192). We therefore
  /// prefer an installed standalone emulator over a RetroArch-core auto-default
  /// so normal launches work out of the box — matching the manual workaround
  /// users otherwise perform on every game.
  ///
  /// Precedence, after an explicit user default (`is_user_default`), which
  /// [_systemDefault] has already honoured, installed or not:
  ///   1. Prefer any positively-installed standalone for the system.
  ///   2. Otherwise the configured default if it looks installed, else any
  ///      installed emulator, else the configured default unchanged (so behavior
  ///      is identical to before when nothing is installed).
  ///
  /// Known, irreducible limitation: a RetroArch core's real install state
  /// cannot be verified on a stock device. Its `.so` lives in RetroArch's
  /// private `0700` data dir, unreadable from our sandbox, and neostation must
  /// never assume/require root — so `isCoreInstalled` fails OPEN (unknown →
  /// treated as installed). Consequently, on a system that has ONLY an
  /// uninstalled RetroArch core and no installed standalone, step 2 can still
  /// return that core and the launch will fail. Step 1 (prefer an installed
  /// standalone) minimizes this but cannot eliminate it without root or an
  /// install-state API RetroArch does not expose.
  static Future<CoreEmulatorModel?> _resolveDefaultInstalledEmulator(
    SystemModel system,
  ) async {
    final configured = await EmulatorRepository.getDefaultEmulatorForSystem(
      system.id!,
    );

    List<CoreEmulatorModel> all;
    try {
      all = await loadEmulatorsForSystem(system);
    } catch (_) {
      // Enumeration failed → preserve prior behavior.
      return configured;
    }

    bool isInstalledUid(String? uid) {
      if (uid == null) return false;
      for (final e in all) {
        if (e.uniqueId == uid && e.isInstalled) return true;
      }
      return false;
    }

    // 1. Prefer a genuinely-installed standalone. This is what fixes the
    //    non-rooted case: even when a RetroArch core is (falsely) reported
    //    installed, a real standalone is the reliable choice.
    for (final e in all) {
      if (e.isInstalled && e.isStandalone) return e;
    }

    // 2. Fall back through installed configured default → any installed → raw.
    if (isInstalledUid(configured?.uniqueId)) return configured;
    for (final e in all) {
      if (e.isInstalled) return e;
    }
    return configured;
  }
}

/// Remembers each system's auto-resolved default emulator for [maxAge].
///
/// Resolving it asks the platform whether each of the system's emulators is
/// installed (a round trip per emulator on Android), which a caller syncing
/// one game at a time would otherwise repeat for every game. Only that answer
/// is kept: the user's own choices are a cheap read and can change at any
/// moment. Install state changes outside the app, hence the short [maxAge].
class InstalledDefaultCache {
  /// How long an answer is trusted.
  static const maxAge = Duration(seconds: 30);

  final DateTime Function() _now;
  final _entries =
      <String, ({DateTime at, Future<CoreEmulatorModel?> emulator})>{};

  InstalledDefaultCache({@visibleForTesting DateTime Function()? now})
    : _now = now ?? DateTime.now;

  Future<CoreEmulatorModel?> _get(
    String systemId,
    Future<CoreEmulatorModel?> Function() resolve,
  ) {
    final now = _now();
    final entry = _entries[systemId];
    if (entry != null && now.difference(entry.at) < maxAge) {
      return entry.emulator;
    }
    final emulator = resolve();
    _entries[systemId] = (at: now, emulator: emulator);
    // A failure is not an answer: the next caller asks again.
    emulator.catchError((Object _) {
      if (identical(_entries[systemId]?.emulator, emulator)) {
        _entries.remove(systemId);
      }
      return null;
    });
    return emulator;
  }
}
