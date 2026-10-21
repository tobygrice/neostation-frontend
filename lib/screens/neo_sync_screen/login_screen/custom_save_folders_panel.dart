import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/models/core_emulator_model.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import 'package:neostation/utils/app_shortcuts.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/widgets/core_footer.dart';

/// Dialog that lets the user pick a system + emulator and select a folder.
///
/// The configured-folder list lives in the full-screen view, not here. Folder
/// selection and sync run in the parent view so they survive Android
/// backgrounding; the dialog closes with the B button or the footer Close
/// control.
///
/// On a controller, up/down move between the system picker, the emulator
/// picker and the Select folder button, and A opens or presses the focused
/// one. While a picker's menu is open the same buttons drive the menu: up/down
/// move through its entries, and scroll it while held, A picks one and B
/// closes it.
///
/// Opened on a configured folder, it starts filled in with that folder's
/// system, emulator and path, ready to change any of them.
class CustomSaveFoldersDialog extends StatefulWidget {
  /// The systems offered, each of which has at least one entry in
  /// [emulatorsBySystem].
  final List<SystemModel> systems;

  /// The standalone emulators each system offers, keyed by folder name.
  final Map<String, List<CoreEmulatorModel>> emulatorsBySystem;

  final Future<void> Function(String system, String emulatorUniqueId)
  onSelectFolder;

  /// The configured folder being edited, or null to configure a new one.
  final CustomSaveFolder? editing;

  const CustomSaveFoldersDialog({
    super.key,
    required this.systems,
    required this.emulatorsBySystem,
    required this.onSelectFolder,
    this.editing,
  });

  @override
  State<CustomSaveFoldersDialog> createState() =>
      _CustomSaveFoldersDialogState();
}

/// The dialog's controller-focusable rows, top to bottom.
enum _Row { system, emulator, selectFolder }

class _CustomSaveFoldersDialogState extends State<CustomSaveFoldersDialog> {
  static const _layerId = 'custom_save_folders_dialog';

  late GamepadNavigation _gamepadNav;
  final _systemFocus = FocusNode(debugLabel: 'custom-folder-system');
  final _emulatorFocus = FocusNode(debugLabel: 'custom-folder-emulator');
  String? _selectedSystem;
  List<CoreEmulatorModel> _emulators = [];
  String? _selectedEmulatorUniqueId;
  bool _pickingFolder = false;
  bool _closed = false;
  _Row _focusedRow = _Row.system;

  /// The highlight strategy [_showMenuFocus] replaced, put back on dispose;
  /// null while it has replaced none.
  FocusHighlightStrategy? _replacedHighlightStrategy;

  @override
  void initState() {
    super.initState();
    _prefill();
    _gamepadNav = GamepadNavigation(
      // Held directions repeat only in an open picker's menu (see _navigate).
      onNavigateUp: (bool isRepeat) =>
          _navigate(TraversalDirection.up, isRepeat: isRepeat),
      onNavigateDown: (bool isRepeat) =>
          _navigate(TraversalDirection.down, isRepeat: isRepeat),
      onSelectItem: _activate,
      onBack: _back,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gamepadNav.initialize();
      // Modal so a screen mounting behind the dialog cannot take the
      // controller from it. The folder picker it hands over to is modal too.
      GamepadNavigationManager.pushLayer(
        _layerId,
        // Not once closing: a folder picker that returns before the exit
        // animation ends hands the controller back to this layer.
        onActivate: () {
          if (!_closed) _gamepadNav.activate();
        },
        onDeactivate: () => _gamepadNav.deactivate(),
        modal: true,
      );
    });
  }

  @override
  void dispose() {
    if (_replacedHighlightStrategy case final strategy?) {
      FocusManager.instance.highlightStrategy = strategy;
    }
    GamepadNavigationManager.popLayer(_layerId);
    _gamepadNav.dispose();
    _systemFocus.dispose();
    _emulatorFocus.dispose();
    super.dispose();
  }

  /// Fills the pickers in from [CustomSaveFoldersDialog.editing], as far as
  /// this OS still offers its system and emulator: a picker's value has to be
  /// one of its entries. The controller starts on Select folder, the quickest
  /// edit, with the pickers a press up away.
  void _prefill() {
    final editing = widget.editing;
    if (editing == null) return;
    final (:system, :emulatorUniqueId, path: _) = editing;
    final emulators = widget.emulatorsBySystem[system];
    if (emulators == null) return;
    _selectedSystem = system;
    _emulators = emulators;
    _focusedRow = _Row.emulator;
    if (emulators.any((e) => e.uniqueId == emulatorUniqueId)) {
      _selectedEmulatorUniqueId = emulatorUniqueId;
      _focusedRow = _Row.selectFolder;
    }
  }

  /// Whether a picker's menu is open over the dialog. The menu is a route of
  /// its own, so the dialog's route stops being the current one.
  bool get _menuOpen => !(ModalRoute.of(context)?.isCurrent ?? true);

  /// The rows the controller can land on: the emulator picker once there is a
  /// system, and the button once there is an emulator.
  List<_Row> get _focusableRows => [
    _Row.system,
    if (_emulators.isNotEmpty) _Row.emulator,
    if (_selectedEmulatorUniqueId != null && !_pickingFolder) _Row.selectFolder,
  ];

  /// Applies [intent] to the open menu's focused entry, unless the key press
  /// that asked for it already has.
  ///
  /// A controller reaches only this dialog's navigator, but a keyboard key
  /// reaches Flutter's focus system as well, straight afterwards (see
  /// `appShortcuts`): Enter activates the focused entry there too, and so do
  /// the arrows where the platform keeps them. Acting a microtask later, and
  /// only when the key left the menu as it found it, does each press once. An
  /// entry activated twice pops twice, and the second pop closes the dialog.
  void _driveMenu(Intent intent) {
    _showMenuFocus();
    final before = FocusManager.instance.primaryFocus;
    scheduleMicrotask(() {
      if (!mounted || !_menuOpen) return;
      final entry = FocusManager.instance.primaryFocus;
      if (entry != before) return;
      final entryContext = entry?.context;
      if (entryContext != null) Actions.maybeInvoke(entryContext, intent);
    });
  }

  /// Moves the controller's focus [direction], answering whether to count it
  /// as a move: the navigator plays the move sound only for one.
  ///
  /// A held direction scrolls an open menu, but the short form beneath it
  /// moves one row per press, so a repeat never moves the form. That also
  /// keeps a direction still held as a menu closes from carrying on down the
  /// form. A first press on the form counts as a move even at its first or
  /// last row, as it always has.
  bool _navigate(TraversalDirection direction, {required bool isRepeat}) {
    if (_menuOpen) return _moveInMenu(direction, isRepeat: isRepeat);
    if (isRepeat) return false;
    final rows = _focusableRows;
    final next =
        rows.indexOf(_focusedRow) +
        (direction == TraversalDirection.up ? -1 : 1);
    if (next >= 0 && next < rows.length) {
      setState(() => _focusedRow = rows[next]);
    }
    return true;
  }

  /// Moves the open menu's focus [direction], answering whether it moved.
  ///
  /// Where the app keeps Flutter's arrow-key shortcuts (see `appShortcuts`),
  /// an arrow key moves the menu through Flutter's focus system as well, and
  /// repeats there while held. That press goes the deferred way of
  /// [_driveMenu], and the navigator's repeats of it are declined. Any other
  /// press, a controller's included, moves the menu straight away, so a held
  /// direction scrolls it and stops at its first or last entry.
  bool _moveInMenu(TraversalDirection direction, {required bool isRepeat}) {
    if (_arrowKeyMovesMenu) {
      if (isRepeat) return false;
      _driveMenu(DirectionalFocusIntent(direction));
      return true;
    }
    _showMenuFocus();
    return FocusManager.instance.primaryFocus?.focusInDirection(direction) ??
        false;
  }

  /// Whether an arrow key is down where Flutter's focus system moves an open
  /// menu on it too: where `appShortcuts` keeps the default directional
  /// shortcuts, or replaces none of them.
  static bool get _arrowKeyMovesMenu {
    final keepsArrows =
        appShortcuts()?.values.any(
          (intent) => intent is DirectionalFocusIntent,
        ) ??
        true;
    return keepsArrows &&
        HardwareKeyboard.instance.logicalKeysPressed.any(_arrowKeys.contains);
  }

  static final _arrowKeys = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  };

  void _activate() {
    if (_menuOpen) {
      // Pick the focused entry, which closes the menu.
      _driveMenu(const ActivateIntent());
      return;
    }
    switch (_focusedRow) {
      case _Row.system:
        _openMenu(_systemFocus);
      case _Row.emulator:
        if (_emulators.isNotEmpty) _openMenu(_emulatorFocus);
      case _Row.selectFolder:
        _selectFolder();
    }
  }

  /// Opens the menu of the picker that owns [focusNode], as a tap would.
  void _openMenu(FocusNode focusNode) {
    final picker = focusNode.context;
    if (picker == null) return;
    _showMenuFocus();
    Actions.maybeInvoke(picker, const ActivateIntent());
  }

  /// Makes an open menu show the entry the controller is on.
  ///
  /// An entry draws its focus only in Flutter's traditional highlight mode,
  /// which a keyboard switches to but the controller, read through the
  /// gamepads plugin rather than as key events, never does. On Android, where
  /// the mode stays touch, the entry the controller moved to looked like the
  /// rest. Only a controller-driven menu does this; [dispose] puts the
  /// strategy back.
  void _showMenuFocus() {
    final focus = FocusManager.instance;
    _replacedHighlightStrategy ??= focus.highlightStrategy;
    focus.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
  }

  void _back() {
    if (!mounted) return;
    // With a menu open, B closes just the menu: it is the top route.
    if (_menuOpen) {
      Navigator.of(context).pop();
      return;
    }
    _close();
  }

  /// Closes the dialog, taking input off it first so nothing it would still
  /// hear during its exit animation reaches the screen behind it twice. Only
  /// the first call pops: a second would pop the screen behind the dialog.
  void _close() {
    if (_closed) return;
    _closed = true;
    _gamepadNav.deactivate();
    Navigator.of(context).pop();
  }

  void _onSystemSelected(String? folderName) {
    setState(() {
      _selectedSystem = folderName;
      _emulators = folderName == null
          ? []
          : widget.emulatorsBySystem[folderName] ?? [];
      _selectedEmulatorUniqueId = null;
      // Straight on to the emulator, the next thing to pick.
      if (_emulators.isNotEmpty) _focusedRow = _Row.emulator;
    });
  }

  void _onEmulatorSelected(String? uniqueId) {
    setState(() {
      _selectedEmulatorUniqueId = uniqueId;
      if (uniqueId != null) _focusedRow = _Row.selectFolder;
    });
  }

  Future<void> _selectFolder() async {
    final system = _selectedSystem;
    final emulatorUniqueId = _selectedEmulatorUniqueId;
    if (system == null || emulatorUniqueId == null || _pickingFolder) return;

    setState(() => _pickingFolder = true);
    // Closing the dialog before opening the SAF picker avoids the dialog being
    // disposed mid-flight on Android resume; the parent view completes the
    // operation and refreshes the list.
    if (mounted) _close();
    await widget.onSelectFolder(system, emulatorUniqueId);
  }

  /// The room [_focusRing] takes around a picker: its padding and border.
  double get _ringInset => 4.r;

  /// Marks the picker on [row] as the controller's focus with a ring.
  Widget _focusRing(_Row row, Widget child) {
    final focused = _focusedRow == row;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: EdgeInsets.all(2.r),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(
          color: focused
              ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.8)
              : Colors.transparent,
          width: 2.r,
        ),
      ),
      child: child,
    );
  }

  /// Marks the Select folder button as the controller's focus with the glow
  /// the login forms give their buttons.
  Widget _focusGlow(Widget child) {
    final focused = _focusedRow == _Row.selectFolder;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8.r),
        boxShadow: [
          if (focused)
            BoxShadow(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.5),
              blurRadius: 8.r,
              spreadRadius: 2.r,
            ),
        ],
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final selectDecoration = InputDecoration(
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 8.r),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r)),
    );
    // A picker's style replaces the theme's text style, colour included, in
    // the field and in its menu, so it names the colour that reads on the
    // menu's surface. Without one, a light theme's menu was white on white.
    final selectStyle = TextStyle(
      fontSize: 12.r,
      color: theme.colorScheme.onSurface,
    );
    // Size only, so a hint keeps the picker's hint and disabled colours.
    final hintStyle = TextStyle(fontSize: 12.r);

    // The controller drives this dialog, so Flutter focus is kept off its
    // widgets: a keyboard Enter would otherwise also open whichever picker
    // Flutter last focused, on top of the one the controller focus is on.
    return ExcludeFocus(
      child: AlertDialog(
        title: Row(
          children: [
            Icon(
              Symbols.folder_special_rounded,
              size: 18.r,
              color: theme.colorScheme.primary,
            ),
            SizedBox(width: 8.r),
            Expanded(
              child: Text(
                AppLocale.customSaveFoldersTitle.getString(context),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 13.r,
                ),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: SizedBox(
            width: 340.r,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _focusRing(
                  _Row.system,
                  DropdownButtonFormField<String>(
                    key: const ValueKey('custom-folder-system'),
                    focusNode: _systemFocus,
                    initialValue: _selectedSystem,
                    // Fill the field and ellipsize long names, rather than size
                    // to the widest item and overflow the dialog.
                    isExpanded: true,
                    decoration: selectDecoration,
                    style: selectStyle,
                    dropdownColor: theme.colorScheme.surface,
                    hint: Text(
                      AppLocale.customSaveFolderPickSystem.getString(context),
                      style: hintStyle,
                    ),
                    items: widget.systems
                        .map(
                          (s) => DropdownMenuItem(
                            value: s.folderName,
                            child: Text(
                              '${s.realName} (${s.folderName})',
                              overflow: TextOverflow.ellipsis,
                              style: selectStyle,
                            ),
                          ),
                        )
                        .toList(),
                    onTap: () => setState(() => _focusedRow = _Row.system),
                    onChanged: _onSystemSelected,
                  ),
                ),
                SizedBox(height: 4.r),
                _focusRing(
                  _Row.emulator,
                  DropdownButtonFormField<String>(
                    key: const ValueKey('custom-folder-emulator'),
                    focusNode: _emulatorFocus,
                    initialValue: _selectedEmulatorUniqueId,
                    // Fill the field and ellipsize long names, rather than size
                    // to the widest item and overflow the dialog.
                    isExpanded: true,
                    decoration: selectDecoration,
                    style: selectStyle,
                    dropdownColor: theme.colorScheme.surface,
                    hint: Text(
                      AppLocale.customSaveFolderPickEmulator.getString(context),
                      style: hintStyle,
                    ),
                    items: _emulators
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.uniqueId,
                            child: Text(
                              e.name,
                              overflow: TextOverflow.ellipsis,
                              style: selectStyle,
                            ),
                          ),
                        )
                        .toList(),
                    onTap: () => setState(() => _focusedRow = _Row.emulator),
                    onChanged: _onEmulatorSelected,
                  ),
                ),
                SizedBox(height: 6.r),
                // Inset by the pickers' ring, so its edges line up with
                // the fields inside them.
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: _ringInset),
                  child: _focusGlow(
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        // Squared off to the fields' corners, so the glow
                        // follows its edge.
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8.r),
                          ),
                        ),
                        onPressed:
                            _pickingFolder || _selectedEmulatorUniqueId == null
                            ? null
                            : _selectFolder,
                        icon: Icon(Symbols.folder_open_rounded, size: 14.r),
                        label: Text(
                          AppLocale.customSaveFolderSelect.getString(context),
                          style: TextStyle(fontSize: 11.r),
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.editing?.path case final path?) ...[
                  SizedBox(height: 6.r),
                  // The folder configured now, which Select folder replaces.
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: _ringInset),
                    child: Text(
                      path,
                      key: const ValueKey('custom-folder-current-path'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 9.r,
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actionsPadding: EdgeInsets.fromLTRB(16.r, 8.r, 16.r, 12.r),
        actions: [
          Align(
            alignment: Alignment.centerRight,
            child: GamepadControl(
              label: AppLocale.close.getString(context),
              iconPath: 'assets/images/gamepad/Xbox_B_button.png',
              onTap: _close,
              textColor: theme.colorScheme.onTertiary,
              backgroundColor: theme.colorScheme.tertiary,
            ),
          ),
        ],
      ),
    );
  }
}
