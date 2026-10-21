import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/save_file_patterns.dart';
import 'package:neostation/services/launcher_service.dart';

/// An emulator's optional `save_files` in its system definition: which of the
/// files in its Standalone Save Folder are Saves and which are Save States.
/// Read from the real system definitions, so the JSON's key spelling and this
/// code stay honest about each other.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final launcher = LauncherService.instance;

  setUpAll(() async {
    for (final system in ['ds', 'gba', 'c64', 'naomi', 'cv']) {
      expect(await launcher.loadSystemConfig('$system.json'), isTrue);
    }
  });

  test('WatermelonDS declares its saves, under either extension it can be '
      'set to write, and its states', () {
    final patterns = launcher.getSaveFilePatterns(
      'ds',
      'ds.standalone.melonds.dual',
    );

    expect(patterns.classify('Game.sav'), SaveFileKind.save);
    expect(patterns.classify('Game.srm'), SaveFileKind.save);
    expect(patterns.classify('GAME.SRM'), SaveFileKind.save);
    expect(patterns.classify('Game.ml1'), SaveFileKind.state);
    expect(patterns.classify('Game.dsv'), isNull);
  });

  test('DraStic declares its saves, its states and the folders it keeps '
      'them in', () {
    final patterns = launcher.getSaveFilePatterns(
      'ds',
      'ds.standalone.drastic',
    );

    expect(patterns.classify('Game.dsv'), SaveFileKind.save);
    expect(patterns.classify('Game_0.dss'), SaveFileKind.state);
    expect(patterns.classify('Game.cfg'), isNull);
    expect(patterns.dirs, {
      SaveFileKind.save: 'backup',
      SaveFileKind.state: 'savestates',
    });
  });

  test('GBA.emu syncs its saves, and leaves its states and per-game '
      'settings alone', () {
    final patterns = launcher.getSaveFilePatterns(
      'gba',
      'gba.com.explusalpha.GbaEmu',
    );

    expect(patterns.classify('Game.sav'), SaveFileKind.save);
    // `Game0.sgm`: the slot follows the ROM's name with no separator, which
    // the name rule cannot tell from another title's, so it is not declared.
    expect(patterns.classify('Game0.sgm'), isNull);
    expect(patterns.classify('Game.config'), isNull);
  });

  test('C64.emu declares no saves at all, only states', () {
    final patterns = launcher.getSaveFilePatterns(
      'c64',
      'c64.com.explusalpha.C64Emu',
    );

    expect(patterns.classify('Game.0.vsf'), SaveFileKind.state);
    expect(patterns.classify('Game.sav'), isNull);
    expect(patterns.classify('Game.config'), isNull);
  });

  test('Flycast\'s arcade saves keep the ROM\'s extension in their names', () {
    final patterns = launcher.getSaveFilePatterns(
      'naomi',
      'naomi.com.flycast.emulator',
    );

    expect(patterns.classify('mvsc2.zip.nvmem'), SaveFileKind.save);
    expect(patterns.classify('mvsc2.zip.eeprom'), SaveFileKind.save);
    expect(patterns.classify('mvsc2_1.state'), SaveFileKind.state);
  });

  test('RAMeka tells its numbered states from its saves', () {
    final patterns = launcher.getSaveFilePatterns('cv', 'cv.ramek');

    expect(patterns.classify('Game.sav'), SaveFileKind.save);
    expect(patterns.classify('Game.S01'), SaveFileKind.state);
  });

  test('an emulator that declares nothing has every file as a save, and '
      'no states', () {
    final patterns = launcher.getSaveFilePatterns(
      'ds',
      'ds.standalone.Seedless',
    );

    expect(patterns.classify('Game.dsv'), SaveFileKind.save);
    expect(patterns.classify('Game.state'), SaveFileKind.save);
    expect(patterns.dirs, isEmpty);
  });

  test('an emulator or system that is not loaded declares nothing', () {
    expect(
      launcher.getSaveFilePatterns('ds', 'no.such.emulator').classify('X.srm'),
      SaveFileKind.save,
    );
    expect(
      launcher.getSaveFilePatterns('nope', 'nope').classify('X.srm'),
      SaveFileKind.save,
    );
  });

  test('a malformed declaration reads as absent, never as an error', () {
    for (final json in [
      'not an object',
      42,
      ['*.srm'],
      {'saves': '*.srm', 'states': 7},
      {
        'saves': [3, null],
      },
    ]) {
      final patterns = SaveFilePatterns.fromJson(json);
      expect(patterns.classify('Game.srm'), SaveFileKind.save, reason: '$json');
      expect(patterns.classify('Game.ml1'), SaveFileKind.save, reason: '$json');
    }
  });

  test('only declared entries of a partly valid list count', () {
    final patterns = SaveFilePatterns.fromJson({
      'saves': ['*.srm', 4],
      'states': ['*.st?'],
    });

    expect(patterns.classify('Game.srm'), SaveFileKind.save);
    expect(patterns.classify('Game.st1'), SaveFileKind.state);
    expect(patterns.classify('Game.dsv'), isNull);
  });

  test('an empty saves list means no file is a save', () {
    final patterns = SaveFilePatterns.fromJson({
      'saves': <String>[],
      'states': ['*.sta'],
    });

    expect(patterns.classify('Game.sav'), isNull);
    expect(patterns.classify('Game.0a.sta'), SaveFileKind.state);
    expect(patterns.declares(SaveFileKind.save), isTrue);
  });

  test('a bracketed class matches one of the characters it lists', () {
    final patterns = SaveFilePatterns.fromJson({
      'saves': ['*.sav', 'a[b.txt', 'x[].txt'],
      'states': ['*.s[0-9][0-9]', '*.fc[s0-9]'],
    });

    expect(patterns.classify('Game.s01'), SaveFileKind.state);
    expect(patterns.classify('Game.S99'), SaveFileKind.state);
    expect(patterns.classify('Game.fcs'), SaveFileKind.state);
    expect(patterns.classify('Game.fc7'), SaveFileKind.state);
    expect(patterns.classify('Game.sav'), SaveFileKind.save);
    expect(patterns.classify('Game.fcx'), isNull);
    // An unclosed or empty class is literal.
    expect(patterns.classify('a[b.txt'), SaveFileKind.save);
    expect(patterns.classify('x[].txt'), SaveFileKind.save);
  });

  test('dirs are read as relative folders, and anything else is dropped', () {
    expect(
      SaveFilePatterns.fromJson({
        'dirs': {'saves': 'backup/', 'states': r'data\states'},
      }).dirs,
      {SaveFileKind.save: 'backup', SaveFileKind.state: 'data/states'},
    );
    for (final dir in ['', '/abs', '../up', 'a/../b', 'C:/x', 5, null]) {
      expect(
        SaveFilePatterns.fromJson({
          'dirs': {'saves': dir},
        }).dirs,
        isEmpty,
        reason: '$dir',
      );
    }
    expect(SaveFilePatterns.fromJson({'dirs': 'backup'}).dirs, isEmpty);
  });

  test('every save_files in the system definitions is well formed', () {
    var declared = 0;
    for (final file in Directory(
      'assets/systems',
    ).listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      final system = jsonDecode(file.readAsStringSync()) as Map;
      for (final emulator in (system['emulators'] as List? ?? const [])) {
        final json = (emulator as Map)['save_files'];
        if (json == null) continue;
        declared++;
        final where = '${file.path} ${emulator['unique_id']}';
        expect(json, isA<Map>(), reason: where);
        json as Map;
        expect(
          json.keys.toSet().difference({'saves', 'states', 'dirs'}),
          isEmpty,
          reason: where,
        );
        for (final key in ['saves', 'states']) {
          final globs = json[key];
          if (globs == null) continue;
          expect(globs, isA<List>(), reason: '$where $key');
          for (final glob in globs as List) {
            expect(glob, isA<String>(), reason: '$where $key');
            expect(glob as String, isNotEmpty, reason: '$where $key');
          }
        }
        final patterns = SaveFilePatterns.fromJson(json);
        expect(
          patterns.dirs.length,
          (json['dirs'] as Map? ?? const {}).length,
          reason: '$where dirs',
        );
        if (json['saves'] != null) {
          expect(patterns.declares(SaveFileKind.save), isTrue, reason: where);
        }
      }
    }
    expect(declared, greaterThan(1));
  });
}
