/// Whether a save file is a Save or a Save State.
enum SaveFileKind {
  save('saves'),
  state('states');

  const SaveFileKind(this.root);

  /// The root a located file's relative path starts with (`saves/...`).
  /// Also the kind's key in a `save_files` declaration.
  final String root;

  /// [state] when [isState], else [save].
  static SaveFileKind of({required bool isState}) => isState ? state : save;
}

/// A standalone emulator's optional `save_files` declaration in its system
/// definition: case-insensitive file-name globs saying which of the files in
/// its Standalone Save Folder are Saves and which are Save States, and the
/// subfolders it keeps each in.
///
/// ```json
/// "save_files": {
///   "saves": ["*.dsv"],
///   "states": ["*.dss"],
///   "dirs": { "saves": "backup", "states": "savestates" }
/// }
/// ```
///
/// Every key is optional. Without `saves`, every file that is not a state is a
/// Save, which keeps the many emulators nobody has described yet working; an
/// empty `saves` list says the emulator keeps no Saves at all. Without
/// `states`, nothing is a Save State. The same lists apply on every OS.
///
/// A glob's `*` matches any run of characters, `?` any one, and `[...]` any
/// one of the characters or `a-z` ranges it lists.
class SaveFilePatterns {
  /// Globs naming Saves, or null for "every file that is not a state".
  final List<String>? saves;

  /// Globs naming Save States, or null for "no file is a state".
  final List<String>? states;

  /// The subfolder of the Standalone Save Folder, as a relative path with `/`
  /// separators, where the emulator keeps each kind by default. A RomM Asset
  /// with no local file to sit beside goes there when the folder has it.
  final Map<SaveFileKind, String> dirs;

  const SaveFilePatterns({this.saves, this.states, this.dirs = const {}});

  /// An emulator that declares nothing: every file is a Save.
  static const none = SaveFilePatterns();

  /// Reads a `save_files` value. Anything malformed reads as absent, so a bad
  /// systems update degrades to "every file is a save" rather than failing.
  /// So does a list whose entries are all unusable: it was meant to name
  /// something, and reading it as empty would leave the emulator with no
  /// saves at all.
  factory SaveFilePatterns.fromJson(Object? json) {
    if (json is! Map) return none;
    List<String>? list(Object? value) {
      if (value is! List) return null;
      if (value.isEmpty) return const [];
      final globs = [
        for (final v in value)
          if (v is String && v.isNotEmpty) v,
      ];
      return globs.isEmpty ? null : globs;
    }

    final dirsJson = json['dirs'];
    return SaveFilePatterns(
      saves: list(json['saves']),
      states: list(json['states']),
      dirs: {
        if (dirsJson is Map)
          for (final kind in SaveFileKind.values)
            kind: ?_relativeDir(dirsJson[kind.root]),
      },
    );
  }

  /// [value] as a relative folder path with `/` separators, or null when it
  /// is not one: not a string, empty, absolute, or stepping out with `..`.
  static String? _relativeDir(Object? value) {
    if (value is! String) return null;
    final normalised = value.replaceAll('\\', '/');
    if (normalised.startsWith('/') || normalised.contains(':')) return null;
    final segments = [
      for (final s in normalised.split('/'))
        if (s.isNotEmpty && s != '.') s,
    ];
    if (segments.isEmpty || segments.contains('..')) return null;
    return segments.join('/');
  }

  /// Whether this emulator's definition says which files are of [kind], so
  /// that classifying a file as [kind] means more than "not a state".
  bool declares(SaveFileKind kind) =>
      (kind == SaveFileKind.save ? saves : states) != null;

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

  /// `*` matches any run of characters, `?` any one, and `[...]` any one of
  /// those it lists (`[0-9]`); everything else, an unclosed `[` included, is
  /// literal. Matched against the whole file name, ignoring case.
  static RegExp _globToRegExp(String glob) {
    final pattern = StringBuffer('^');
    var i = 0;
    while (i < glob.length) {
      final char = glob[i];
      final close = char == '[' ? glob.indexOf(']', i + 1) : -1;
      if (close > i + 1) {
        pattern.write('[${_classBody(glob.substring(i + 1, close))}]');
        i = close + 1;
        continue;
      }
      pattern.write(switch (char) {
        '*' => '.*',
        '?' => '.',
        _ => RegExp.escape(char),
      });
      i++;
    }
    pattern.write(r'$');
    return RegExp(pattern.toString(), caseSensitive: false);
  }

  /// A glob class's characters, escaped for a regular expression class, with
  /// `-` between two of them kept as a range.
  static String _classBody(String body) {
    final out = StringBuffer();
    for (var i = 0; i < body.length; i++) {
      final char = body[i];
      final isRange = char == '-' && i > 0 && i < body.length - 1;
      out.write(isRange ? '-' : RegExp.escape(char));
    }
    return out.toString();
  }
}
