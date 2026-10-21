/// Whether a save file is a Save or a Save State.
enum SaveFileKind {
  save('saves'),
  state('states');

  const SaveFileKind(this.root);

  /// The root a located file's relative path starts with (`saves/...`).
  final String root;

  /// [state] when [isState], else [save].
  static SaveFileKind of({required bool isState}) => isState ? state : save;
}

/// A standalone emulator's optional `save_files` declaration in its system
/// definition: case-insensitive file-name globs saying which of the files in
/// its Standalone Save Folder are Saves and which are Save States.
///
/// ```json
/// "save_files": { "saves": ["*.srm"], "states": ["*.ml?"] }
/// ```
///
/// Both lists are optional. Without `saves`, every file that is not a state is
/// a Save, which keeps the many emulators nobody has described yet working.
/// Without `states`, nothing is a Save State. The same lists apply on every OS.
class SaveFilePatterns {
  /// Globs naming Saves, or null for "every file that is not a state".
  final List<String>? saves;

  /// Globs naming Save States, or null for "no file is a state".
  final List<String>? states;

  const SaveFilePatterns({this.saves, this.states});

  /// An emulator that declares nothing: every file is a Save.
  static const none = SaveFilePatterns();

  /// Reads a `save_files` value. Anything malformed reads as absent, so a bad
  /// systems update degrades to "every file is a save" rather than failing.
  /// So does a list with no usable glob: an empty `saves` would otherwise
  /// leave the emulator with no saves at all.
  factory SaveFilePatterns.fromJson(Object? json) {
    if (json is! Map) return none;
    List<String>? list(Object? value) {
      if (value is! List) return null;
      final globs = [
        for (final v in value)
          if (v is String && v.isNotEmpty) v,
      ];
      return globs.isEmpty ? null : globs;
    }

    return SaveFilePatterns(
      saves: list(json['saves']),
      states: list(json['states']),
    );
  }

  /// What [fileName] is to this emulator, or null when it is neither and must
  /// be left alone. States are checked first, so a file both lists name is a
  /// state.
  SaveFileKind? classify(String fileName) {
    final states = this.states;
    if (states != null && _matchesAny(states, fileName)) {
      return SaveFileKind.state;
    }
    final saves = this.saves;
    if (saves == null || _matchesAny(saves, fileName)) return SaveFileKind.save;
    return null;
  }

  static bool _matchesAny(List<String> globs, String fileName) => globs.any(
    (glob) => _compiled
        .putIfAbsent(glob, () => _globToRegExp(glob))
        .hasMatch(fileName),
  );

  /// Each glob compiled once, however many files it is matched against. The
  /// system definitions hold only a handful.
  static final Map<String, RegExp> _compiled = {};

  /// `*` matches any run of characters and `?` any one; everything else is
  /// literal. Matched against the whole file name, ignoring case.
  static RegExp _globToRegExp(String glob) {
    final pattern = StringBuffer('^');
    for (final char in glob.split('')) {
      pattern.write(switch (char) {
        '*' => '.*',
        '?' => '.',
        _ => RegExp.escape(char),
      });
    }
    pattern.write(r'$');
    return RegExp(pattern.toString(), caseSensitive: false);
  }
}
