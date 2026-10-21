import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/save_file_patterns.dart';
import 'package:neostation/sync/providers/romm_provider.dart';

/// Every `save_files` declaration in the system definitions, held against the
/// files its emulator really writes.
///
/// A glob can be well formed and match a file the emulator writes, yet never
/// sync: RomM keeps only files named after the ROM and drops images as
/// thumbnails ([RomMSyncProvider.syncableSaves]). Stella's `<cart>_flash.dat`
/// and GBA.emu's `<rom>0.sgm` were declared and could never move, and SkyEmu's
/// `.state.png` states were dropped as thumbnails. Names made up from the
/// globs cannot catch that (`Game.a26_flash.dat` passes the name rule where
/// Stella writes `Game_flash.dat`), so each declared emulator lists here the
/// names it writes, from its source where that is open, and:
///
/// * every glob must match one of its emulator's names, so a declaration
///   comes with the names it was made from;
/// * every name must be one RomM syncs, as the kind the declaration says.
///
/// `{name}` is the ROM's file name without its extension, and `{rom}` the ROM
/// file name itself, for the emulators that keep its extension.
const _written = <String, List<String>>{
  // EmuEx (emu-ex-plus-alpha): `stateFilename` in each `<System>.emu`
  // Main.cc, slots `0`-`9` plus an auto slot `a`/`A`; Mednafen-based cores
  // write `{name}.nc<slot>`, optionally with an MD5 before it.
  'com.explusalpha.A2600Emu': ['{name}.00.sta', '{name}.0a.sta'],
  'com.explusalpha.C64Emu': ['{name}.0.vsf', '{name}.a.vsf'],
  'com.explusalpha.GbaEmu': ['{name}.sav'],
  'com.explusalpha.GbcEmu': [
    '{name}.sav',
    '{name}.rtc',
    '{name}.00.gqs',
    '{name}.0A.gqs',
  ],
  'com.explusalpha.LynxEmu': ['{name}.nc0', '{name}.nca'],
  'com.explusalpha.MdEmu': [
    '{name}.srm',
    '{name}.brm',
    '{name}.00.gp',
    '{name}.0a.gp',
  ],
  'com.explusalpha.MsxEmu': ['{name}.sram', '{name}.00.sta'],
  'com.explusalpha.NeoEmu': [
    '{name}.nv',
    '{name}.memcard',
    '{name}.00.sta',
    '{name}.0A.sta',
  ],
  'com.explusalpha.NesEmu': ['{name}.sav', '{name}.fc0', '{name}.fcs'],
  'com.explusalpha.NgpEmu': ['{name}.ngf', '{name}.nc0', '{name}.nca'],
  'com.explusalpha.SaturnEmu': [
    '{name}.bkr',
    '{name}.bcr',
    '{name}.smpc',
    '{name}.seep',
    '{name}.arp',
    '{name}.nc0',
    '{name}.ncq',
  ],
  'com.explusalpha.Snes9xPlus': [
    '{name}.srm',
    '{name}.rtc',
    '{name}.00.frz',
    '{name}.0A.frz',
  ],
  'com.explusalpha.SwanEmu': ['{name}.sav', '{name}.flash', '{name}.nc0'],
  'com.PceEmu': ['{name}.sav', '{name}.mg0', '{name}.nc0', '{name}.ncq'],

  // Stella: states are `<Cart_Name>.st<slot>` (StateManager.cxx). Its flash
  // and EEPROM files are `<Cart_Name>_flash.dat` / `_eeprom.dat`, which the
  // name rule cannot tell from another title's, so none is declared.
  'com.stella.emulator': ['{name}.st0', '{name}.st9'],

  // Flycast and Reicast: arcade NVRAM and per-game VMUs keep the ROM's
  // extension (`get_game_save_prefix`); states drop it and number from 1.
  'com.flycast.emulator': [
    '{rom}.nvmem',
    '{rom}.nvmem2',
    '{rom}.eeprom',
    '{rom}_vmu_save_A1.bin',
    '{name}.state',
    '{name}_1.state',
  ],
  'com.reicast.emulator': [
    '{rom}.nvmem',
    '{rom}.nvmem2',
    '{rom}.eeprom',
    '{name}.state',
  ],

  // DuckStation: per-game cards named after the file (`Card1Type =
  // PerGameFileTitle`). Its states are named after the disc serial
  // (`SCUS-94900_1.sav`), so none is declared.
  'com.github.stenzek.duckstation': ['{name}_1.mcd', '{name}_2.mcd'],

  'ramek': ['{name}.sav', '{name}.S01'],
  'com.izzy2lost.super3': ['{name}.nv', '{name}.st0'],

  'standalone.drastic': ['{name}.dsv', '{name}_0.dss'],
  'standalone.melonds': ['{name}.sav', '{name}.ml1'],
  'standalone.melonds.nightly': ['{name}.sav', '{name}.ml1'],
  'standalone.melonds.dev': ['{name}.sav', '{name}.ml1'],
  'standalone.melonds.dual': ['{name}.sav', '{name}.srm', '{name}.ml1'],
  'standalone.noods': ['{name}.sav', '{name}.noo'],

  // SkyEmu: slot states are PNG images, the autosave is raw (main.c).
  'com.sky.SkyEmu': [
    '{name}.sav',
    '{name}.slot0.state.png',
    '{name}.autosave.state.raw',
  ],
  'com.fastemulator.gba': ['{name}.sav'],
  'com.fastemulator.gbafree': ['{name}.sav'],
  'com.fastemulator.gbc': ['{name}.sav', '{name}.rtc'],
  'com.fastemulator.gbcfree': ['{name}.sav', '{name}.rtc'],
  'com.pixelrespawn.linkboy': ['{name}.sav'],
  'it.dbtecno.pizzaboygba': ['{name}.sav'],
  'it.dbtecno.pizzaboygbapro': ['{name}.sav'],
};

/// The ROM name the names are written for: spaces and brackets, as real
/// libraries have.
const _romName = 'Super Game (USA)';

/// An emulator's `save_files`, the system it is declared for and that
/// system's ROM extensions.
typedef _Declaration = ({
  String where,
  String emulator,
  SaveFilePatterns patterns,
  Map<String, List<String>> globs,
  List<String> romExtensions,
});

/// Every declaration in `assets/systems`. [_Declaration.emulator] is the
/// unique id without its system, so one emulator's names serve every system
/// it is declared for.
List<_Declaration> _declarations() => [
  for (final file in Directory('assets/systems').listSync().whereType<File>())
    if (file.path.endsWith('.json'))
      ..._declarationsIn(file.path, jsonDecode(file.readAsStringSync()) as Map),
];

Iterable<_Declaration> _declarationsIn(String where, Map definition) sync* {
  final extensions = [
    for (final e in (definition['system'] as Map)['extensions'] as List? ?? [])
      e.toString().toLowerCase().replaceFirst(RegExp(r'^\.'), ''),
  ];
  for (final emulator in definition['emulators'] as List? ?? const []) {
    final json = (emulator as Map)['save_files'];
    if (json is! Map) continue;
    final uniqueId = emulator['unique_id'] as String;
    yield (
      where: '$where $uniqueId',
      emulator: uniqueId.substring(uniqueId.indexOf('.') + 1),
      patterns: SaveFilePatterns.fromJson(json),
      globs: {
        for (final kind in SaveFileKind.values)
          kind.root: [
            for (final glob in json[kind.root] as List? ?? const [])
              glob as String,
          ],
      },
      romExtensions: extensions,
    );
  }
}

/// The ROM file of [declaration]'s system the names are written for.
String _romFile(_Declaration declaration) =>
    '$_romName.${declaration.romExtensions.firstOrNull ?? 'bin'}';

/// [declaration]'s emulator's names, for [_romFile].
List<String> _namesFor(_Declaration declaration) => [
  for (final name in _written[declaration.emulator] ?? const <String>[])
    name
        .replaceAll('{rom}', _romFile(declaration))
        .replaceAll('{name}', _romName),
];

void main() {
  final declarations = _declarations();

  test('the system definitions declare save files', () {
    expect(declarations, isNotEmpty);
  });

  // Each test lists every problem it finds, not just the first.

  test('every declared glob matches a name its emulator writes', () {
    final problems = <String>[];
    for (final declaration in declarations) {
      final names = _namesFor(declaration);
      if (names.isEmpty) {
        problems.add(
          '${declaration.where}: list the names it writes in _written, '
          'keyed ${declaration.emulator}',
        );
        continue;
      }
      for (final kind in SaveFileKind.values) {
        for (final glob in declaration.globs[kind.root]!) {
          final only = kind == SaveFileKind.save
              ? SaveFilePatterns(saves: [glob], states: const [])
              : SaveFilePatterns(saves: const [], states: [glob]);
          if (!names.any((name) => only.classify(name) == kind)) {
            problems.add(
              '${declaration.where}: ${kind.root} glob $glob matches none '
              'of $names',
            );
          }
        }
      }
    }
    expect(problems, isEmpty);
  });

  test('every name a declared emulator writes is one RomM syncs, as the kind '
      'its declaration says', () {
    final problems = <String>[];
    for (final declaration in declarations) {
      final game = GameModel(
        romname: _romFile(declaration),
        realname: _romName,
        name: _romName,
        year: '',
        developer: '',
        publisher: '',
        genre: '',
        players: '',
        rating: 0,
      );
      for (final name in _namesFor(declaration)) {
        final kind = declaration.patterns.classify(name);
        if (kind == null) {
          problems.add(
            '${declaration.where}: $name is neither a save nor a state',
          );
          continue;
        }
        final kept = RomMSyncProvider.syncableSaves(
          game,
          [
            LocalSaveFile(
              filePath: '/folder/$name',
              fileName: name,
              fileSize: 1,
              lastModified: DateTime.utc(2026, 10, 21),
              gameName: _romName,
              isSynced: false,
              relativePath: '${kind.root}/$name',
            ),
          ],
          romExtensions: declaration.romExtensions.toSet(),
          patterns: declaration.patterns,
        );
        if (kept.isEmpty) {
          problems.add('${declaration.where}: RomM would not sync $name');
        }
      }
    }
    expect(problems, isEmpty);
  });

  test('names are listed only for emulators that declare save files', () {
    final declared = {for (final d in declarations) d.emulator};
    expect(_written.keys.toSet().difference(declared), isEmpty);
  });
}
