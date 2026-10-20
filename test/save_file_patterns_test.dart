import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/save_file_patterns.dart';
import 'package:neostation/services/launcher_service.dart';

/// An emulator's optional `save_files` in its system definition: which of the
/// files in its Standalone Save Folder are Saves and which are Save States.
/// Read from the real `ds.json`, so the JSON's key spelling and this code stay
/// honest about each other.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final launcher = LauncherService.instance;

  setUpAll(() async {
    expect(await launcher.loadSystemConfig('ds.json'), isTrue);
  });

  test('WatermelonDS declares its saves and states', () {
    final patterns = launcher.getSaveFilePatterns(
      'ds',
      'ds.standalone.melonds.dual',
    );

    expect(patterns.classify('Game.srm'), SaveFileKind.save);
    expect(patterns.classify('GAME.SRM'), SaveFileKind.save);
    expect(patterns.classify('Game.ml1'), SaveFileKind.state);
    expect(patterns.classify('Game.sav'), isNull);
  });

  test('an emulator that declares nothing has every file as a save, and '
      'no states', () {
    final patterns = launcher.getSaveFilePatterns(
      'ds',
      'ds.standalone.drastic',
    );

    expect(patterns.classify('Game.dsv'), SaveFileKind.save);
    expect(patterns.classify('Game.state'), SaveFileKind.save);
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
}
