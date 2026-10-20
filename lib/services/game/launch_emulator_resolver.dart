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

  static Future<LaunchEmulator> resolve(
    SystemModel system,
    GameModel game,
  ) async {
    final perGame = game.emulatorName;
    if (perGame != null) {
      return LaunchEmulator(perGame, 'per-game override', isExplicit: true);
    }
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
    final defaultEmu = await _resolveDefaultInstalledEmulator(system);
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
  /// Decided by the emulator's own row, which records whether it is standalone
  /// the same way on every platform (a RetroArch package on Android, a
  /// RetroArch executable on desktop). [CoreEmulatorModel.isRetroArch] is not
  /// that test: it reads the Android package, so it is false for every
  /// RetroArch Core on desktop. An id with no row on this device falls back to
  /// the `.ra.`/`.ra32.`/`.ra64.` naming the system definitions follow.
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
        if (e.uniqueId == uniqueId) return !e.isStandalone;
      }
    }
    return RegExp(r'\.ra(32|64)?\.').hasMatch(uniqueId.toLowerCase());
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
  /// Precedence:
  ///   1. An explicit user default (`is_user_default`) is always honored,
  ///      installed or not — it's a deliberate choice.
  ///   2. Otherwise prefer any positively-installed standalone for the system.
  ///   3. Otherwise the configured default if it looks installed, else any
  ///      installed emulator, else the configured default unchanged (so behavior
  ///      is identical to before when nothing is installed).
  ///
  /// Known, irreducible limitation: a RetroArch core's real install state
  /// cannot be verified on a stock device. Its `.so` lives in RetroArch's
  /// private `0700` data dir, unreadable from our sandbox, and neostation must
  /// never assume/require root — so `isCoreInstalled` fails OPEN (unknown →
  /// treated as installed). Consequently, on a system that has ONLY an
  /// uninstalled RetroArch core and no installed standalone, step 3 can still
  /// return that core and the launch will fail. Step 2 (prefer an installed
  /// standalone) minimizes this but cannot eliminate it without root or an
  /// install-state API RetroArch does not expose.
  static Future<CoreEmulatorModel?> _resolveDefaultInstalledEmulator(
    SystemModel system,
  ) async {
    // 1. Explicit user choice wins outright.
    final userDefault =
        await EmulatorRepository.getUserDefaultEmulatorForSystem(system.id!);
    if (userDefault != null) return userDefault;

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

    // 2. Prefer a genuinely-installed standalone. This is what fixes the
    //    non-rooted case: even when a RetroArch core is (falsely) reported
    //    installed, a real standalone is the reliable choice.
    for (final e in all) {
      if (e.isInstalled && e.isStandalone) return e;
    }

    // 3. Fall back through installed configured default → any installed → raw.
    if (isInstalledUid(configured?.uniqueId)) return configured;
    for (final e in all) {
      if (e.isInstalled) return e;
    }
    return configured;
  }
}
