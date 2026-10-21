import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:neostation/data/datasources/sqlite_migrations.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/game/launch_emulator_resolver.dart';
import 'package:neostation/services/launcher_service.dart';
import 'package:neostation/services/neosync/neo_sync_service.dart';
import 'package:neostation/services/romm_service.dart';
import 'package:neostation/sync/providers/romm_provider.dart';

import 'database_test_helper.dart';

/// RomM sync of standalone emulator saves through Standalone Save Folders.
///
/// Every game syncs only where its Launch Emulator keeps its saves: RetroArch's
/// folders for a RetroArch Core, the configured Standalone Save Folder for a
/// standalone emulator, and nothing at all for a standalone emulator with no
/// folder. Driven through the provider's public per-game hooks against a fake
/// RomM server, real temporary folders and the real `ds.json` definition, so
/// the path resolution under test is the provider's own.
class _Upload {
  _Upload(this.romId, this.name, {required this.isState, this.slot});
  final int romId;
  final String name;
  final bool isState;
  final String? slot;

  @override
  String toString() =>
      '${isState ? 'state' : 'save'} $romId/$name${slot == null ? '' : ' @$slot'}';
}

/// In-memory RomM server holding saves and states per ROM.
class _FakeRommService extends RommService {
  final Map<int, List<RommAsset>> savesByRom = {};
  final Map<int, List<RommAsset>> statesByRom = {};
  final Map<String, List<int>> contentByPath = {};
  final List<_Upload> uploads = [];
  final List<int> listCalls = [];
  int _nextAssetId = 1;
  int _stampSeq = 0;

  DateTime _stamp() =>
      DateTime.now().toUtc().add(Duration(seconds: ++_stampSeq));

  /// Plants an asset as if another client had uploaded it.
  RommAsset seed(
    int romId,
    String fileName,
    List<int> bytes, {
    bool isState = false,
    DateTime? updatedAt,
    String? slot,
  }) {
    final path = 'assets/$romId/${_nextAssetId}_$fileName';
    final asset = RommAsset(
      id: _nextAssetId++,
      romId: romId,
      fileName: fileName,
      fileSizeBytes: bytes.length,
      isState: isState,
      updatedAt: updatedAt ?? _stamp(),
      slot: slot,
      downloadPath: path,
    );
    contentByPath[path] = List.of(bytes);
    ((isState ? statesByRom : savesByRom)[romId] ??= []).add(asset);
    return asset;
  }

  @override
  bool get playtimeSyncAvailable => false;

  @override
  Future<List<RommAsset>> listSaves({required int romId}) async {
    listCalls.add(romId);
    return List.of(savesByRom[romId] ?? const []);
  }

  @override
  Future<List<RommAsset>> listStates({required int romId}) async =>
      List.of(statesByRom[romId] ?? const []);

  @override
  Future<RommAsset> uploadSave(
    int romId,
    File file, {
    String? emulator,
    String? slot,
    String? deviceId,
    bool overwrite = true,
  }) async {
    final name = p.basename(file.path);
    uploads.add(_Upload(romId, name, isState: false, slot: slot));
    return seed(romId, name, await file.readAsBytes(), slot: slot);
  }

  @override
  Future<RommAsset> uploadState(
    int romId,
    File file, {
    String? emulator,
    String? slot,
    String? deviceId,
    bool overwrite = true,
  }) async {
    final name = p.basename(file.path);
    uploads.add(_Upload(romId, name, isState: true, slot: slot));
    return seed(romId, name, await file.readAsBytes(), isState: true);
  }

  @override
  Future<RommAsset> updateSave(int assetId, File file) =>
      _update(savesByRom, assetId, file);

  @override
  Future<RommAsset> updateState(int assetId, File file) =>
      _update(statesByRom, assetId, file);

  Future<RommAsset> _update(
    Map<int, List<RommAsset>> byRom,
    int assetId,
    File file,
  ) async {
    for (final entry in byRom.entries) {
      final i = entry.value.indexWhere((a) => a.id == assetId);
      if (i < 0) continue;
      final old = entry.value[i];
      final bytes = await file.readAsBytes();
      uploads.add(
        _Upload(entry.key, old.fileName, isState: old.isState, slot: old.slot),
      );
      contentByPath[old.downloadPath!] = List.of(bytes);
      final updated = RommAsset(
        id: old.id,
        romId: old.romId,
        fileName: old.fileName,
        fileSizeBytes: bytes.length,
        isState: old.isState,
        updatedAt: _stamp(),
        slot: old.slot,
        downloadPath: old.downloadPath,
      );
      entry.value[i] = updated;
      return updated;
    }
    throw StateError('no asset with id $assetId');
  }

  @override
  Future<Uint8List> downloadAssetByPath(String downloadPath) async =>
      Uint8List.fromList(contentByPath[downloadPath]!);

  @override
  Future<Uint8List> downloadSaveContent(int assetId) async =>
      throw UnimplementedError('tests always provide download_path');
}

class _FakeBrowse extends RommProvider {
  _FakeBrowse(this.fakeService);
  final RommService fakeService;

  @override
  bool get isConnected => true;

  @override
  RommService get service => fakeService;
}

/// Stands in for RetroArch's own folder resolution, which reads RetroArch's
/// config. Everything else (the standalone folders, the Launch Emulator, the
/// name rule) is the provider's.
class _RetroArchFolders {
  _RetroArchFolders(this.saves, this.states);

  final Directory saves;
  final Directory states;

  /// Extra files the real locator would also report, such as those in a
  /// Standalone Save Folder it appends for the system.
  final List<String> alsoFound = [];

  Future<List<LocalSaveFile>> locate(GameModel game) async {
    final found = <LocalSaveFile>[];
    void add(File file, String relativePath) {
      final stat = file.statSync();
      found.add(
        LocalSaveFile(
          filePath: file.path,
          fileName: p.basename(file.path),
          fileSize: stat.size,
          lastModified: stat.modified,
          gameName: game.name,
          isSynced: false,
          relativePath: relativePath,
        ),
      );
    }

    for (final (dir, root) in [(saves, 'saves'), (states, 'states')]) {
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        add(f, '$root/${p.relative(f.path, from: dir.path)}');
      }
    }
    for (final extra in alsoFound) {
      if (File(extra).existsSync()) {
        add(File(extra), 'saves/${p.basename(extra)}');
      }
    }
    return found;
  }

  Future<List<String>> resolveTargets(
    GameModel game,
    String relativeName,
  ) async {
    final m = RegExp(r'^(saves|states)/(.+)$').firstMatch(relativeName)!;
    final base = m.group(1) == 'states' ? states : saves;
    return [p.join(base.path, m.group(2)!)];
  }
}

const _watermelon = 'ds.standalone.melonds.dual';
const _drastic = 'ds.standalone.drastic';

/// A standalone emulator whose definition declares no `save_files`.
const _seedless = 'ds.standalone.Seedless';
const _raMelon = 'ds.ra.melonds';

GameModel _game(String romname, {String? emulator}) => GameModel(
  romname: romname,
  realname: romname,
  name: romname,
  year: '2005',
  developer: '',
  publisher: '',
  genre: '',
  players: '',
  rating: 0,
  romPath: '/roms/ds/$romname',
  systemFolderName: 'ds',
  cloudSyncEnabled: true,
  emulatorName: emulator,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final helper = DatabaseTestHelper();
  late DatabaseAdapter db;
  late Directory tmp;
  late Directory watermelonDir;
  late _RetroArchFolders retroArch;
  late _FakeRommService server;

  /// The provider with its own path resolution throughout, for standalone
  /// cases.
  late RomMSyncProvider provider;

  /// The same, with [retroArch] standing in for RetroArch's folders, for
  /// cases where a game's saves are, or could wrongly be taken from,
  /// RetroArch's.
  late RomMSyncProvider withRetroArch;

  /// The library the upload retry walks.
  var library = <GameModel>[];

  setUpAll(() async {
    expect(await LauncherService.instance.loadSystemConfig('ds.json'), isTrue);
  });

  Future<void> addEmulator(
    String uniqueId, {
    required bool standalone,
    bool isDefault = false,
  }) => db.execute(
    'INSERT INTO app_emulators (system_id, os_id, name, unique_identifier, '
    'is_standalone, is_default, is_default_core, is_ra_compatible) '
    'VALUES (?, 1, ?, ?, ?, ?, 0, 0)',
    ['ds', uniqueId, uniqueId, standalone ? 1 : 0, isDefault ? 1 : 0],
  );

  Future<void> configureFolder(String emulator, Directory dir) => db.execute(
    'INSERT INTO user_custom_save_folders '
    '(system_folder_name, emulator_slug, folder_path) VALUES (?, ?, ?)',
    ['ds', emulator, dir.path],
  );

  Future<void> link(String romname, int romId) =>
      RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: romname,
        systemFolder: 'ds',
        rommRomId: romId,
      );

  File write(Directory dir, String name, String content) {
    final file = File(p.join(dir.path, name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  setUp(() async {
    db = await helper.setUp();
    await db.execute(SqliteMigrations.createAppRommRomMapTableSql);
    await db.execute('INSERT INTO app_os (id, name) VALUES (1, ?)', [
      SqliteService.getCurrentOs(),
    ]);
    await db.execute('''
      INSERT INTO app_systems (id, real_name, folder_name, neosync_json)
      VALUES ('ds', 'Nintendo DS', 'ds', '{"sync": true}')
    ''');
    for (final ext in ['nds', 'zip', '7z', 'bin', 'rar']) {
      await db.execute(
        'INSERT INTO app_system_extensions (system_id, extension) '
        'VALUES (?, ?)',
        ['ds', ext],
      );
    }
    await addEmulator(_raMelon, standalone: false, isDefault: true);
    await addEmulator(_watermelon, standalone: true);
    await addEmulator(_drastic, standalone: true);
    await addEmulator(_seedless, standalone: true);

    tmp = await Directory.systemTemp.createTemp('romm_standalone');
    watermelonDir = Directory(p.join(tmp.path, 'watermelon'))..createSync();
    retroArch = _RetroArchFolders(
      Directory(p.join(tmp.path, 'ra_saves'))..createSync(),
      Directory(p.join(tmp.path, 'ra_states'))..createSync(),
    );
    await configureFolder(_watermelon, watermelonDir);
    await link('Game.nds', 1);
    library = [];

    server = _FakeRommService();
    provider = RomMSyncProvider(
      _FakeBrowse(server),
      NeoSyncProvider(NeoSyncService()),
      listGames: () async => library,
      autoSweep: false,
    );
    withRetroArch = RomMSyncProvider(
      _FakeBrowse(server),
      NeoSyncProvider(NeoSyncService()),
      locateSaves: retroArch.locate,
      resolveTargets: retroArch.resolveTargets,
      listGames: () async => library,
      autoSweep: false,
    );
  });

  tearDown(() async {
    provider.dispose();
    withRetroArch.dispose();
    await helper.tearDown();
    await tmp.delete(recursive: true);
  });

  group('placement in the standalone folder', () {
    test('a newer remote save overwrites the local one in place', () async {
      final local = write(watermelonDir, 'Game.srm', 'LOCAL');
      local.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 1)),
      );
      server.seed(1, 'Game [2026-10-20_10-00-00].srm', 'REMOTE'.codeUnits);

      await provider.syncGameSavesBeforeLaunch(
        _game('Game.nds', emulator: _watermelon),
      );

      expect(local.readAsStringSync(), 'REMOTE');
      expect(watermelonDir.listSync(), hasLength(1));
      expect(server.uploads, isEmpty);
    });

    test('a server-only save lands at the folder root when the game has no '
        'local save', () async {
      server.seed(1, 'Game [2026-10-20_10-00-00].srm', 'REMOTE'.codeUnits);

      await provider.syncGameSavesBeforeLaunch(
        _game('Game.nds', emulator: _watermelon),
      );

      expect(
        File(p.join(watermelonDir.path, 'Game.srm')).readAsStringSync(),
        'REMOTE',
      );
    });

    test('a server-only save lands beside the game\'s other local save, '
        'not at the root', () async {
      final sub = Directory(p.join(watermelonDir.path, 'nested', 'saves'));
      write(sub, 'Game_1.srm', 'OTHER SLOT');
      server.seed(1, 'Game.srm', 'REMOTE'.codeUnits);

      await provider.syncGameSavesBeforeLaunch(
        _game('Game.nds', emulator: _watermelon),
      );

      expect(File(p.join(sub.path, 'Game.srm')).readAsStringSync(), 'REMOTE');
      expect(
        File(p.join(watermelonDir.path, 'Game.srm')).existsSync(),
        isFalse,
      );
    });
  });

  group('the Launch Emulator decides which copy syncs', () {
    /// The bytes of the save uploaded for ROM 1, which say whose copy went up.
    String uploadedSave() {
      final asset = server.savesByRom[1]!.single;
      return String.fromCharCodes(server.contentByPath[asset.downloadPath]!);
    }

    setUp(() {
      write(watermelonDir, 'Game.srm', 'WATERMELON');
      write(retroArch.saves, 'Game.srm', 'RETROARCH');
    });

    Future<void> setUserDefault(String emulator) => db.execute(
      'INSERT INTO user_emulator_config '
      '(emulator_unique_id, emulator_path, is_user_default) VALUES (?, ?, 1)',
      [emulator, ''],
    );

    Future<void> setAppDefault(String emulator) => db.execute(
      'UPDATE app_emulators SET is_default = '
      'CASE unique_identifier WHEN ? THEN 1 ELSE 0 END',
      [emulator],
    );

    test('the game\'s own emulator choice comes first', () async {
      await setUserDefault(_raMelon);

      await withRetroArch.syncGameSavesAfterClose(
        _game('Game.nds', emulator: _watermelon),
      );

      expect(uploadedSave(), 'WATERMELON');
    });

    test(
      'a per-game RetroArch choice beats a standalone system default',
      () async {
        await setUserDefault(_watermelon);

        await withRetroArch.syncGameSavesAfterClose(
          _game('Game.nds', emulator: _raMelon),
        );

        expect(uploadedSave(), 'RETROARCH');
      },
    );

    test('then the system default the user picked', () async {
      await setUserDefault(_watermelon);

      await withRetroArch.syncGameSavesAfterClose(_game('Game.nds'));

      expect(uploadedSave(), 'WATERMELON');
    });

    test('then the default launch would pick on its own', () async {
      await setAppDefault(_watermelon);

      await withRetroArch.syncGameSavesAfterClose(_game('Game.nds'));

      expect(uploadedSave(), 'WATERMELON');
    });

    test('a RetroArch default syncs RetroArch\'s copy', () async {
      await withRetroArch.syncGameSavesAfterClose(_game('Game.nds'));

      expect(uploadedSave(), 'RETROARCH');
    });
  });

  group('only the Launch Emulator\'s location syncs', () {
    test('a RetroArch game ignores files in a Standalone Save Folder, even '
        'ones the RetroArch resolution reports', () async {
      // The real resolution appends the system's standalone folders.
      retroArch.alsoFound.add(write(watermelonDir, 'Game.srm', 'STRAY').path);

      await withRetroArch.syncGameSavesAfterClose(
        _game('Game.nds', emulator: _raMelon),
      );

      expect(server.uploads, isEmpty);
    });

    test('a RetroArch game\'s download goes to RetroArch, never the '
        'standalone folder', () async {
      server.seed(1, 'Game.srm', 'REMOTE'.codeUnits);

      await withRetroArch.syncGameSavesBeforeLaunch(
        _game('Game.nds', emulator: _raMelon),
      );

      expect(
        File(p.join(retroArch.saves.path, 'Game.srm')).readAsStringSync(),
        'REMOTE',
      );
      expect(watermelonDir.listSync(), isEmpty);
    });

    test('a standalone game ignores RetroArch\'s leftovers', () async {
      write(retroArch.saves, 'Game.srm', 'LEFTOVER');
      write(retroArch.states, 'Game.state', 'LEFTOVER');

      await withRetroArch.syncGameSavesAfterClose(
        _game('Game.nds', emulator: _watermelon),
      );

      expect(server.uploads, isEmpty);
    });
  });

  group('saves versus states', () {
    test('a file matching the emulator\'s state patterns goes up as a state, '
        'the save as a save in the autosave slot', () async {
      write(watermelonDir, 'Game.srm', 'SAVE');
      write(watermelonDir, 'Game.ml1', 'STATE');

      await provider.syncGameSavesAfterClose(
        _game('Game.nds', emulator: _watermelon),
      );

      expect(
        server.uploads.map((u) => '$u'),
        unorderedEquals(['save 1/Game.srm @autosave', 'state 1/Game.ml1']),
      );
    });

    test('a file matching neither list stays local', () async {
      write(watermelonDir, 'Game.dsv', 'OTHER EMULATOR');

      await provider.syncGameSavesAfterClose(
        _game('Game.nds', emulator: _watermelon),
      );

      expect(server.uploads, isEmpty);
    });

    test('remote assets are filtered by the same patterns', () async {
      server.seed(1, 'Game.dsv', 'NOT A WATERMELON SAVE'.codeUnits);
      server.seed(1, 'Game.state', 'RETROARCH STATE'.codeUnits, isState: true);
      server.seed(1, 'Game.ml2', 'WATERMELON STATE'.codeUnits, isState: true);

      await provider.syncGameSavesBeforeLaunch(
        _game('Game.nds', emulator: _watermelon),
      );

      expect(watermelonDir.listSync().map((e) => p.basename(e.path)), [
        'Game.ml2',
      ]);
    });

    test('an emulator that declares no patterns syncs every file as a save, '
        'and no states', () async {
      final seedlessDir = Directory(p.join(tmp.path, 'seedless'))..createSync();
      await configureFolder(_seedless, seedlessDir);
      write(seedlessDir, 'Game.dsv', 'SAVE');
      write(seedlessDir, 'Game_0.dss', 'A STATE');
      server.seed(1, 'Game.state', 'RETROARCH STATE'.codeUnits, isState: true);
      final seedless = _game('Game.nds', emulator: _seedless);

      await provider.syncGameSavesBeforeLaunch(seedless);
      await provider.syncGameSavesAfterClose(seedless);

      expect(
        server.uploads.map((u) => '$u'),
        unorderedEquals([
          'save 1/Game.dsv @autosave',
          'save 1/Game_0.dss @autosave',
        ]),
      );
      expect(
        File(p.join(seedlessDir.path, 'Game.state')).existsSync(),
        isFalse,
      );
    });

    test(
      'a save left on RomM under a state\'s name is never downloaded',
      () async {
        // An earlier version uploaded every file as a save, states included.
        server.seed(1, 'Game.ml1', 'STATE UPLOADED AS A SAVE'.codeUnits);

        await provider.syncGameSavesBeforeLaunch(
          _game('Game.nds', emulator: _watermelon),
        );

        expect(watermelonDir.listSync(), isEmpty);
      },
    );
  });

  group('which files count', () {
    // Seedless declares no patterns, so every file is a save and the name rule
    // alone decides.
    late Directory seedlessDir;
    final seedless = _game('Game.nds', emulator: _seedless);

    setUp(() async {
      seedlessDir = Directory(p.join(tmp.path, 'seedless'))..createSync();
      await configureFolder(_seedless, seedlessDir);
    });

    List<String> uploadedNames() => [for (final u in server.uploads) u.name];

    test(
      'only files named after the ROM, then "." or "_<digits>.", go up',
      () async {
        for (final name in [
          'Game.srm',
          'Game.state.auto',
          'Game_1.mcd',
          'Game_0.dss',
          'game.DSV',
          'Super Game.srm',
          'Game [Hack].srm',
          'Game_Hack.srm',
          'Game',
        ]) {
          write(seedlessDir, name, name);
        }

        await provider.syncGameSavesAfterClose(seedless);

        expect(
          uploadedNames(),
          unorderedEquals([
            'Game.srm',
            'Game.state.auto',
            'Game_1.mcd',
            'Game_0.dss',
            'game.DSV',
          ]),
        );
      },
    );

    test(
      'a file inside a game-named folder counts by its own name only',
      () async {
        // Folder Saves: generic names inside a folder per game.
        write(Directory(p.join(seedlessDir.path, 'Game')), 'save.dat', 'X');
        write(
          Directory(p.join(seedlessDir.path, 'SAVEDATA', 'ULUS10041')),
          'PARAM.SFO',
          'X',
        );
        write(Directory(p.join(seedlessDir.path, 'Game')), 'Game.dsv', 'MINE');

        await provider.syncGameSavesAfterClose(seedless);

        expect(uploadedNames(), ['Game.dsv']);
      },
    );

    test(
      'the ROM itself never goes up, from a folder shared with the ROMs',
      () async {
        write(seedlessDir, 'Game.nds', 'ROM');
        write(seedlessDir, 'Game.zip', 'ROM');
        write(seedlessDir, 'Game.dsv', 'SAVE');

        await provider.syncGameSavesAfterClose(seedless);

        expect(uploadedNames(), ['Game.dsv']);
      },
    );

    test(
      'a per-game card sharing an extension with the ROMs still goes up',
      () async {
        // `bin` is a DS ROM extension, as it is for Dreamcast, whose Flycast
        // names per-game VMUs this way.
        write(seedlessDir, 'Game.bin', 'ROM');
        write(seedlessDir, 'Game.A1.bin', 'PER-GAME CARD');

        await provider.syncGameSavesAfterClose(seedless);

        expect(uploadedNames(), ['Game.A1.bin']);
      },
    );

    test('remote assets face the same name rule', () async {
      server.seed(1, 'Super Game.dsv', 'OTHER GAME'.codeUnits);
      server.seed(1, 'Game.nds', 'A ROM'.codeUnits);
      server.seed(1, 'Game [2026-10-20_10-00-00].dsv', 'MINE'.codeUnits);

      await provider.syncGameSavesBeforeLaunch(seedless);

      expect(seedlessDir.listSync().map((e) => p.basename(e.path)), [
        'Game.dsv',
      ]);
    });
  });

  group('the upload retry, scoped to one system', () {
    final ds = _game('Game.nds', emulator: _watermelon);
    final gba = GameModel(
      romname: 'Other.gba',
      realname: 'Other',
      name: 'Other',
      year: '',
      developer: '',
      publisher: '',
      genre: '',
      players: '',
      rating: 0,
      romPath: '/roms/gba/Other.gba',
      systemFolderName: 'gba',
      cloudSyncEnabled: true,
    );

    setUp(() async {
      await RommSaveMapRepository.putMapping(
        source: RommLinkSource.download,
        romname: 'Other.gba',
        systemFolder: 'gba',
        rommRomId: 2,
      );
      library = [ds, gba];
      write(watermelonDir, 'Game.srm', 'DS SAVE');
      write(retroArch.saves, 'Other.srm', 'GBA SAVE');
    });

    test('sends only that system\'s pending saves', () async {
      final result = await withRetroArch.retryPendingUploads(
        systemFolder: 'ds',
      );

      expect(result.success, isTrue);
      expect(server.uploads.map((u) => '$u'), ['save 1/Game.srm @autosave']);
    });

    test(
      'says how many games it uploaded and how many were up to date',
      () async {
        // Linked, but with no saves here: in neither count.
        await link('Empty.nds', 3);
        library.add(_game('Empty.nds', emulator: _watermelon));

        final first = await withRetroArch.retryPendingUploads(
          systemFolder: 'ds',
        );
        final again = await withRetroArch.retryPendingUploads(
          systemFolder: 'ds',
        );

        expect(first, isA<RommSweepResult>());
        expect((first as RommSweepResult).uploaded, 1);
        expect(first.upToDate, 0);
        expect((again as RommSweepResult).uploaded, 0);
        expect(again.upToDate, 1);
      },
    );

    test('unscoped, it still covers every system', () async {
      await withRetroArch.retryPendingUploads();

      expect(
        server.uploads.map((u) => '${u.romId}/${u.name}'),
        unorderedEquals(['1/Game.srm', '2/Other.srm']),
      );
    });

    test('a file in the folder that belongs to no linked game stays local, '
        'without a failure', () async {
      write(watermelonDir, 'Unlinked.srm', 'NOT IN ROMM');

      final result = await withRetroArch.retryPendingUploads(
        systemFolder: 'ds',
      );

      expect(result.success, isTrue);
      expect(server.uploads.map((u) => u.name), ['Game.srm']);
      expect(withRetroArch.uploadFailures.value.isEmpty, isTrue);
    });
  });

  group('a standalone emulator with no folder on this device', () {
    final drastic = _game('Game.nds', emulator: _drastic);

    setUp(() {
      write(retroArch.saves, 'Game.srm', 'RETROARCH');
      server.seed(1, 'Game.dsv', 'REMOTE'.codeUnits);
    });

    test('shows the emulator as missing and lists nothing', () async {
      await withRetroArch.detectGameSaveFiles(drastic);

      expect(
        withRetroArch.getGameSyncState('Game.nds')?.status,
        GameSyncStatus.missingEmulator,
      );
      expect(server.listCalls, isEmpty);
    });

    test('transfers nothing before launch or after close', () async {
      await withRetroArch.syncGameSavesBeforeLaunch(drastic);
      await withRetroArch.syncGameSavesAfterClose(drastic);

      expect(server.listCalls, isEmpty);
      expect(server.uploads, isEmpty);
      expect(retroArch.saves.listSync().map((e) => p.basename(e.path)), [
        'Game.srm',
      ]);
      expect(
        withRetroArch.getGameSyncState('Game.nds')?.status,
        GameSyncStatus.missingEmulator,
      );
    });

    test('has nothing for the upload retry to send', () async {
      library = [drastic];

      final result = await withRetroArch.retryPendingUploads();

      expect(result.success, isTrue);
      expect(server.uploads, isEmpty);
      expect(withRetroArch.uploadFailures.value.isEmpty, isTrue);
    });
  });

  group('a RetroArch Core flagged standalone by mistake', () {
    const misflagged = 'ds.ra.desmume';

    test('still syncs RetroArch\'s copy, as the folders view leaves it out '
        'of Standalone Save Folders', () async {
      await addEmulator(misflagged, standalone: true);
      write(retroArch.saves, 'Game.srm', 'RETROARCH');

      await withRetroArch.syncGameSavesAfterClose(
        _game('Game.nds', emulator: misflagged),
      );

      expect(server.uploads.map((u) => u.name), ['Game.srm']);
      expect(
        withRetroArch.getGameSyncState('Game.nds')?.status,
        isNot(GameSyncStatus.missingEmulator),
      );
    });
  });

  group('a system whose definition opts out of sync', () {
    setUp(() async {
      await db.execute(
        "UPDATE app_systems SET neosync_json = '{\"sync\": false}' "
        "WHERE id = 'ds'",
      );
      write(watermelonDir, 'Game.srm', 'DS SAVE');
      library = [_game('Game.nds', emulator: _watermelon)];
    });

    test('has nothing waiting in its Standalone Save Folder, and the retry '
        'counts nothing as uploaded', () async {
      final result = await provider.retryPendingUploads(systemFolder: 'ds');

      expect(result, isA<RommSweepResult>());
      expect((result as RommSweepResult).uploaded, 0);
      expect(result.upToDate, 0);
      expect(server.uploads, isEmpty);
    });
  });

  group('files of the same name in different subfolders', () {
    test('only the most recently modified one syncs', () async {
      write(
        watermelonDir,
        p.join('old', 'Game.srm'),
        'OLD',
      ).setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));
      write(watermelonDir, p.join('new', 'Game.srm'), 'NEW');

      await provider.syncGameSavesAfterClose(
        _game('Game.nds', emulator: _watermelon),
      );

      expect(server.uploads.map((u) => u.name), ['Game.srm']);
      final asset = server.savesByRom[1]!.single;
      expect(
        String.fromCharCodes(server.contentByPath[asset.downloadPath]!),
        'NEW',
      );
    });
  });

  group('a server-only save with no local file of its kind', () {
    test('lands beside the folder\'s other files with its extension, where '
        'the emulator keeps them', () async {
      final cards = Directory(p.join(watermelonDir.path, 'memcards'));
      write(cards, 'Other.srm', 'ANOTHER GAME');
      server.seed(1, 'Game [2026-10-20_10-00-00].srm', 'REMOTE'.codeUnits);

      await provider.syncGameSavesBeforeLaunch(
        _game('Game.nds', emulator: _watermelon),
      );

      expect(File(p.join(cards.path, 'Game.srm')).readAsStringSync(), 'REMOTE');
      expect(
        File(p.join(watermelonDir.path, 'Game.srm')).existsSync(),
        isFalse,
      );
    });

    test('a state lands beside the folder\'s other states, whatever its slot '
        'number', () async {
      write(Directory(p.join(watermelonDir.path, 'saves')), 'Other.srm', 'S');
      final states = Directory(p.join(watermelonDir.path, 'states'));
      write(states, 'Other.ml1', 'ANOTHER GAME\'S STATE');
      server.seed(1, 'Game.ml3', 'REMOTE'.codeUnits, isState: true);

      await provider.syncGameSavesBeforeLaunch(
        _game('Game.nds', emulator: _watermelon),
      );

      expect(
        File(p.join(states.path, 'Game.ml3')).readAsStringSync(),
        'REMOTE',
      );
    });

    test('lands in the subfolder the emulator\'s definition names for its '
        'kind, even with no file there yet', () async {
      final drasticDir = Directory(p.join(tmp.path, 'DraStic'));
      final backup = Directory(p.join(drasticDir.path, 'backup'))
        ..createSync(recursive: true);
      final savestates = Directory(p.join(drasticDir.path, 'savestates'))
        ..createSync();
      // More files of the kind elsewhere do not outweigh the named subfolder.
      final other = Directory(p.join(drasticDir.path, 'other'));
      write(other, 'A.dsv', 'A');
      write(other, 'B.dsv', 'B');
      await configureFolder(_drastic, drasticDir);
      server.seed(1, 'Game.dsv', 'REMOTE SAVE'.codeUnits);
      server.seed(1, 'Game_0.dss', 'REMOTE STATE'.codeUnits, isState: true);

      await provider.syncGameSavesBeforeLaunch(
        _game('Game.nds', emulator: _drastic),
      );

      expect(
        File(p.join(backup.path, 'Game.dsv')).readAsStringSync(),
        'REMOTE SAVE',
      );
      expect(
        File(p.join(savestates.path, 'Game_0.dss')).readAsStringSync(),
        'REMOTE STATE',
      );
    });

    test('a named subfolder the folder lacks is not made: the folder chosen '
        'may already be it', () async {
      final backup = Directory(p.join(tmp.path, 'DraStic', 'backup'))
        ..createSync(recursive: true);
      await configureFolder(_drastic, backup);
      server.seed(1, 'Game.dsv', 'REMOTE'.codeUnits);

      await provider.syncGameSavesBeforeLaunch(
        _game('Game.nds', emulator: _drastic),
      );

      expect(
        File(p.join(backup.path, 'Game.dsv')).readAsStringSync(),
        'REMOTE',
      );
      expect(Directory(p.join(backup.path, 'backup')).existsSync(), isFalse);
    });

    test('for an emulator that declares nothing, lands beside the files with '
        'its extension', () async {
      final seedlessDir = Directory(p.join(tmp.path, 'seedless'))..createSync();
      final cards = Directory(p.join(seedlessDir.path, 'cards'));
      write(cards, 'Other.dsv', 'ANOTHER GAME');
      final misc = Directory(p.join(seedlessDir.path, 'misc'));
      write(misc, 'a.cfg', 'A');
      write(misc, 'b.cfg', 'B');
      await configureFolder(_seedless, seedlessDir);
      server.seed(1, 'Game.dsv', 'REMOTE'.codeUnits);

      await provider.syncGameSavesBeforeLaunch(
        _game('Game.nds', emulator: _seedless),
      );

      expect(File(p.join(cards.path, 'Game.dsv')).readAsStringSync(), 'REMOTE');
    });
  });

  group('the remembered auto-resolved default', () {
    Future<void> setAppDefault(String emulator) => db.execute(
      'UPDATE app_emulators SET is_default = '
      'CASE unique_identifier WHEN ? THEN 1 ELSE 0 END',
      [emulator],
    );

    test('is reused until it expires, while the user\'s own default is always '
        'read afresh', () async {
      var now = DateTime(2026, 10, 21);
      final cache = InstalledDefaultCache(now: () => now);
      final system = (await SystemRepository.getSystemByFolderName('ds'))!;
      Future<String?> launchEmulator() async =>
          (await LaunchEmulatorResolver.resolve(
            system,
            _game('Game.nds'),
            installedDefaults: cache,
          )).uniqueId;

      expect(await launchEmulator(), _raMelon);

      await setAppDefault(_watermelon);
      now = now.add(const Duration(seconds: 10));
      expect(await launchEmulator(), _raMelon, reason: 'still remembered');

      now = now.add(InstalledDefaultCache.maxAge);
      expect(await launchEmulator(), _watermelon, reason: 'expired');

      await db.execute(
        'INSERT INTO user_emulator_config '
        '(emulator_unique_id, emulator_path, is_user_default) VALUES (?, ?, 1)',
        [_drastic, ''],
      );
      expect(await launchEmulator(), _drastic);
    });
  });
}
