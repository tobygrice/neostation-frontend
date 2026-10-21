import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/save_file_patterns.dart';
import 'package:neostation/sync/providers/romm_provider.dart';

/// Guards the filter RomM applies to NeoSync's save locator.
///
/// The locator matches any file whose name *contains* the game name and applies
/// no extension filter. On a real device one play session of
/// `Extra Mario Bros. [Hacks]` produced four "save states" on the server, two of
/// which were RetroArch's `.png` thumbnails. The same `contains` match is
/// one-way: a game named `Extra Mario Bros.` matches
/// `Extra Mario Bros. [Hacks].state` and would sync a different title's saves
/// as its own.
///
/// The locator itself is deliberately left loose for NeoSync's sake, so RomM's
/// rules live here.
void main() {
  LocalSaveFile file(String path) => LocalSaveFile(
    filePath: path,
    fileName: path.split('/').last,
    fileSize: 1,
    lastModified: DateTime.utc(2026, 8, 5),
    gameName: 'test',
    isSynced: false,
    relativePath: 'states/${path.split('/').last}',
  );

  GameModel game(String romname) => GameModel(
    romname: romname,
    realname: romname,
    name: romname,
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0,
  );

  List<String> namesOf(List<LocalSaveFile> f) =>
      f.map((e) => e.filePath.split('/').last).toList();

  group('thumbnails', () {
    test('drops the .png RetroArch writes beside a state', () {
      final kept = RomMSyncProvider.syncableSaves(
        game('Extra Mario Bros. [Hacks].zip'),
        [
          file('/s/Extra Mario Bros. [Hacks].state'),
          file('/s/Extra Mario Bros. [Hacks].state.png'),
          file('/s/Extra Mario Bros. [Hacks].state.auto'),
          file('/s/Extra Mario Bros. [Hacks].state.auto.png'),
        ],
      );

      expect(namesOf(kept), [
        'Extra Mario Bros. [Hacks].state',
        'Extra Mario Bros. [Hacks].state.auto',
      ]);
    });

    test('keeps the autosave, which is real save data', () {
      final kept = RomMSyncProvider.syncableSaves(game('Game.zip'), [
        file('/s/Game.state.auto'),
      ]);

      expect(namesOf(kept), ['Game.state.auto']);
    });

    test('keeps an image the emulator names as one of its save states', () {
      // SkyEmu writes its slot states as PNG images, its autosave as raw.
      final skyEmu = SaveFilePatterns.fromJson({
        'saves': ['*.sav'],
        'states': ['*.state.raw', '*.state.png'],
      });

      final kept = RomMSyncProvider.syncableSaves(game('Game.gba'), [
        file('/s/Game.slot0.state.png'),
        file('/s/Game.autosave.state.raw'),
      ], patterns: skyEmu);

      expect(namesOf(kept), [
        'Game.slot0.state.png',
        'Game.autosave.state.raw',
      ]);
    });

    test('an image that is a save only because no saves are declared is '
        'still a thumbnail', () {
      final statesOnly = SaveFilePatterns.fromJson({
        'states': ['*.state'],
      });

      final kept = RomMSyncProvider.syncableSaves(game('Game.zip'), [
        file('/s/Game.state'),
        file('/s/Game.state.png'),
      ], patterns: statesOnly);

      expect(namesOf(kept), ['Game.state']);
    });
  });

  group('longer-named titles', () {
    test("a shorter title does not claim a longer title's saves", () {
      // The exact pair observed on the device.
      final kept =
          RomMSyncProvider.syncableSaves(game('Extra Mario Bros..zip'), [
            file('/s/Extra Mario Bros..state'),
            file('/s/Extra Mario Bros. [Hacks].state'),
          ]);

      expect(namesOf(kept), ['Extra Mario Bros..state']);
    });

    test('a title ending in a period keeps its own saves', () {
      final kept = RomMSyncProvider.syncableSaves(
        game('Extra Mario Bros..zip'),
        [file('/s/Extra Mario Bros..state'), file('/s/Extra Mario Bros..srm')],
      );

      expect(namesOf(kept), [
        'Extra Mario Bros..state',
        'Extra Mario Bros..srm',
      ]);
    });

    test('rejects a sibling whose name merely starts the same', () {
      final kept = RomMSyncProvider.syncableSaves(game('Mario.zip'), [
        file('/s/Mario.srm'),
        file('/s/Mario Kart.srm'),
      ]);

      expect(namesOf(kept), ['Mario.srm']);
    });
  });

  // RomM syncs Single-File Saves only. A Shared Memory Card and the
  // generic files inside a Folder Save carry no game name, and that is what
  // keeps them from being attached to every game.
  group('files not named after the game', () {
    test('a shared memory card is left out', () {
      final kept = RomMSyncProvider.syncableSaves(game('Final Fantasy X.iso'), [
        file('/s/Mcd001.ps2'),
      ]);

      expect(namesOf(kept), isEmpty);
    });

    test('a Switch save matched by title id is left out', () {
      final kept = RomMSyncProvider.syncableSaves(game('A Short Hike.nsp'), [
        file('/s/0100F2C0115B6000/save.dat'),
      ]);

      expect(namesOf(kept), isEmpty);
    });
  });
}
