import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/models/core_emulator_model.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/repositories/emulator_repository.dart';
import 'package:neostation/repositories/neosync_save_folder_repository.dart';
import 'package:neostation/repositories/system_repository.dart';
import 'package:neostation/services/permission_service.dart';
import 'package:neostation/services/user_data_location_service.dart';
import 'package:neostation/utils/cloud_path_builder.dart';
import 'package:neostation/widgets/custom_notification.dart' as custom;
import 'package:neostation/widgets/tv_directory_picker.dart';
import 'package:neostation/widgets/core_footer.dart';
import 'package:neostation/widgets/confirm_action_dialog.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';
import '../../app_screen.dart';
import 'custom_save_folders_panel.dart';
import 'neo_sync_shared.dart';

/// Full-screen Custom Save Folders view.
///
/// Lets the user configure per-emulator custom save folders (ARMSX2, DuckStation,
/// ...). Folder selection runs on this view (which survives Android
/// backgrounding while the SAF picker is open), and each configured folder can
/// be re-synced or removed. Replaces the inline panel with its own navigation
/// layer.
/// What a folder's upload sent and what was already there.
typedef SaveFolderUploadCounts = ({int uploaded, int upToDate});

class CustomSaveFoldersView extends StatefulWidget {
  final VoidCallback onBack;

  /// Uploads the saves of a system whose folder was just chosen, for a host
  /// whose Sync Provider is not NeoSync, answering null when it failed.
  /// Without one, the folder's files go to NeoSync.
  final Future<SaveFolderUploadCounts?> Function(String system)?
  uploadSystemSaves;

  const CustomSaveFoldersView({
    super.key,
    required this.onBack,
    this.uploadSystemSaves,
  });

  /// Stands in for the platform folder picker, which tests cannot drive.
  @visibleForTesting
  static Future<String?> Function()? debugPickFolder;

  @override
  State<CustomSaveFoldersView> createState() => _CustomSaveFoldersViewState();
}

class _CustomSaveFoldersViewState extends State<CustomSaveFoldersView> {
  static final _log = LoggerService.instance;

  /// The notification a folder's upload shows, updated in place as it runs.
  static const _uploadNotificationId = 'custom_save_folder_upload';

  late GamepadNavigation _gamepadNav;

  /// The systems with a standalone emulator to configure a folder for.
  List<SystemModel> _systems = [];

  /// The standalone emulators of each of [_systems], keyed by folder name.
  Map<String, List<CoreEmulatorModel>> _emulatorsBySystem = {};
  List<(String, String, String)> _configured = [];
  bool _syncing = false;
  int _selectedFolderIndex = 0;

  /// One per configured folder row, to scroll the focused one into view.
  List<GlobalKey> _folderKeys = [];

  @override
  void initState() {
    super.initState();
    _load();
    _initializeGamepad();
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('neo_sync_custom_folders');
    _gamepadNav.dispose();
    super.dispose();
  }

  void _initializeGamepad() {
    _gamepadNav = GamepadNavigation(
      onNavigateUp: (isRepeat) => _navigateFolders(-1),
      onNavigateDown: (isRepeat) => _navigateFolders(1),
      onPreviousTab: () => AppNavigation.previousTab(),
      onNextTab: () => AppNavigation.nextTab(),
      onBack: () {
        if (mounted) widget.onBack();
      },
      onSelectItem: _editFocusedFolder,
      onSelectButton: _handleSelectFolder,
      onFavorite: () => _openConfigDialog(),
      onSettings: () {},
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'neo_sync_custom_folders',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  void _navigateFolders(int delta) {
    if (_configured.isEmpty) return;
    final newIndex =
        (_selectedFolderIndex + delta + _configured.length) %
        _configured.length;
    if (!mounted) return;
    setState(() => _selectedFolderIndex = newIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final row = _selectedFolderIndex < _folderKeys.length
          ? _folderKeys[_selectedFolderIndex].currentContext
          : null;
      if (row == null || !row.mounted) return;
      Scrollable.ensureVisible(
        row,
        duration: const Duration(milliseconds: 150),
        alignmentPolicy: delta < 0
            ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
            : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  /// Select (View) asks for confirmation, then deletes the focused configured
  /// folder. With nothing configured there is nothing to delete, so it opens
  /// the configure dialog instead. Like the footer's Delete, it does nothing
  /// while a folder is uploading.
  Future<void> _handleSelectFolder() async {
    if (_syncing) return;
    if (_configured.isEmpty) {
      _openConfigDialog();
      return;
    }
    final (system, slug, _) = _configured[_selectedFolderIndex];

    _gamepadNav.deactivate();
    final confirmed = await ConfirmActionDialog.show(
      context,
      title: AppLocale.removeCustomFolder.getString(context),
      body: AppLocale.removeCustomFolderConfirm.getString(context),
      confirmLabel: AppLocale.removeCustomFolder.getString(context),
      cancelLabel: AppLocale.cancel.getString(context),
      icon: Symbols.delete_forever_rounded,
    );
    _gamepadNav.activate();

    if (confirmed != true) return;
    await _removeFolder(system, slug);
  }

  Future<void> _load() => Future.wait([_loadSystems(), _loadConfigured()]);

  /// Loads the systems that have a standalone emulator on this OS, so the
  /// dialog never offers a system with nothing to pick under it.
  Future<void> _loadSystems() async {
    try {
      final systems = await SystemRepository.getAllSystems();
      final emulators = await Future.wait(
        systems.map(
          (s) => EmulatorRepository.getEmulatorsForSystemCurrentOs(
            s.id ?? s.folderName,
          ),
        ),
      );
      final bySystem = <String, List<CoreEmulatorModel>>{};
      for (var i = 0; i < systems.length; i++) {
        final standalone = emulators[i].where(_isStandalone).toList();
        if (standalone.isNotEmpty) bySystem[systems[i].folderName] = standalone;
      }
      if (!mounted) return;
      setState(() {
        _systems = [
          for (final s in systems)
            if (bySystem.containsKey(s.folderName)) s,
        ];
        _emulatorsBySystem = bySystem;
      });
    } catch (e, st) {
      // Non-fatal: the dialog just has no systems to offer.
      _log.e(
        'CustomSaveFolder: loading systems failed',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Standalone folders target standalone emulators (ARMSX2, DuckStation, ...).
  /// RetroArch cores are discovered automatically from their saves dir, so they
  /// must never be offered here — even if a core is mis-flagged as standalone,
  /// its `retroarch.*` slug is the reliable tell.
  static bool _isStandalone(CoreEmulatorModel e) =>
      e.isStandalone &&
      !CloudPathBuilder.slugFromEmulatorUniqueId(
        e.uniqueId,
      ).startsWith('retroarch.');

  /// The configured row's heading: the system's and emulator's names, or their
  /// identifiers for one this OS does not offer.
  String _folderHeading(String system, String emulatorUniqueId) {
    final systemName =
        _systems.where((s) => s.folderName == system).firstOrNull?.realName ??
        system;
    final emulatorName =
        _emulatorsBySystem[system]
            ?.where((e) => e.uniqueId == emulatorUniqueId)
            .firstOrNull
            ?.name ??
        emulatorUniqueId;
    return '$systemName / $emulatorName';
  }

  Future<void> _loadConfigured() async {
    try {
      final configured = await NeoSyncSaveFolderRepository.getAllEntries();
      if (mounted) {
        setState(() {
          _configured = configured;
          _folderKeys = List.generate(configured.length, (_) => GlobalKey());
          if (_selectedFolderIndex >= configured.length) {
            _selectedFolderIndex = configured.isEmpty
                ? 0
                : configured.length - 1;
          }
        });
      }
    } catch (e) {
      // ignore
    }
  }

  /// Picks and saves the folder for [system] and [emulatorSlug], then uploads
  /// its saves.
  ///
  /// [replacing] is the configured folder this edits, as `(system,
  /// emulatorUniqueId, path)`. An edit that moves it to another system or
  /// emulator removes the old entry, so the list keeps one row for it.
  Future<void> _selectFolderFor(
    String system,
    String emulatorSlug, {
    (String, String, String)? replacing,
  }) async {
    _log.i('CustomSaveFolder: picker start for $system / $emulatorSlug');
    try {
      var selected =
          await (CustomSaveFoldersView.debugPickFolder?.call() ??
              _pickFolder(initialDirectory: replacing?.$3));

      if (selected == null || !mounted) return;
      selected = selected.replaceFirst(RegExp(r'[\\/]+$'), '');
      final String folderPath = selected;
      if (!Directory(folderPath).existsSync()) {
        if (mounted) {
          custom.AppNotification.showNotification(
            context,
            AppLocale.customSaveFolderInvalid.getString(context),
            type: custom.NotificationType.error,
          );
        }
        return;
      }

      await NeoSyncSaveFolderRepository.saveFolder(
        system,
        emulatorSlug,
        folderPath,
      );
      if (replacing case (
        final oldSystem,
        final oldEmulator,
        _,
      ) when oldSystem != system || oldEmulator != emulatorSlug) {
        await NeoSyncSaveFolderRepository.removeFolder(oldSystem, oldEmulator);
      }
      await _loadConfigured();
      if (!mounted) return;
      // Keep the cursor on the row just saved, wherever it now sorts.
      final saved = _configured.indexWhere(
        (c) => c.$1 == system && c.$2 == emulatorSlug,
      );
      if (saved != -1) setState(() => _selectedFolderIndex = saved);

      final folderLabel = path.basename(folderPath);
      final upload = widget.uploadSystemSaves;
      setState(() => _syncing = true);
      try {
        final counts = upload != null
            ? await _uploadWith(upload, system, folderLabel)
            : await _uploadToNeoSync(system, emulatorSlug, folderLabel);
        if (!mounted) return;
        if (counts == null) {
          _showUpload(
            AppLocale.customFolderUploadFailed.getString(context),
            custom.NotificationType.error,
          );
        } else {
          _showUpload(
            AppLocale.customFolderUploadComplete
                .getString(context)
                .replaceFirst('{uploaded}', '${counts.uploaded}')
                .replaceFirst('{skipped}', '${counts.upToDate}'),
            custom.NotificationType.success,
            progress: 1,
          );
        }
      } finally {
        if (mounted) setState(() => _syncing = false);
      }
    } catch (e, st) {
      _log.e(
        'CustomSaveFolder: error in _selectFolderFor',
        error: e,
        stackTrace: st,
      );
      if (mounted) {
        custom.AppNotification.showNotification(
          context,
          AppLocale.customFolderUploadFailed.getString(context),
          type: custom.NotificationType.error,
        );
      }
    }
  }

  /// The folder the user picks, as a real path, or null if they pick none.
  ///
  /// On desktop the picker opens at [initialDirectory], the folder being
  /// edited, when there is one.
  Future<String?> _pickFolder({String? initialDirectory}) async {
    // The platform picker on desktop, where Android's SAF picker is no use.
    if (!Platform.isAndroid) {
      return TvDirectoryPicker.pickDirectory(
        context,
        dialogTitle: AppLocale.customSaveFolderSelect.getString(context),
        initialDirectory: initialDirectory,
      );
    }
    final isTV = await PermissionService.isTelevision();
    if (!mounted) return null;

    if (isTV) return TvDirectoryPicker.show(context);
    final uri = await PermissionService.requestFolderAccess();
    if (uri == null) return null;
    final hasFiles = await PermissionService.hasAllFilesAccess();
    return await UserDataLocationService.resolveAndroidUserDataPath(
          uri.toString(),
          hasAllFilesAccess: hasFiles,
        ) ??
        UserDataLocationService.safUriToRealPath(uri.toString());
  }

  /// Shows [message] in the folder upload's notification in the app's
  /// notification centre (header bell), replacing what it said before.
  void _showUpload(
    String message,
    custom.NotificationType type, {
    double? progress,
    bool ongoing = false,
  }) => custom.AppNotification.showNotification(
    context,
    message,
    type: type,
    notificationId: _uploadNotificationId,
    progress: progress,
    ongoing: ongoing,
  );

  /// The upload's progress message for [folderLabel].
  String _uploadingMessage(String folderLabel) => AppLocale
      .uploadingCustomFolder
      .getString(context)
      .replaceFirst('{folder}', folderLabel);

  /// Uploads the folder's existing saves to NeoSync, showing its progress.
  Future<SaveFolderUploadCounts?> _uploadToNeoSync(
    String system,
    String emulatorSlug,
    String folderLabel,
  ) async {
    final provider = context.read<NeoSyncProvider>();
    _showUpload(
      _uploadingMessage(folderLabel),
      custom.NotificationType.info,
      progress: 0,
      ongoing: true,
    );
    void listener() {
      if (!mounted) return;
      _showUpload(
        _uploadingMessage(folderLabel),
        custom.NotificationType.info,
        progress: provider.syncProgress,
        ongoing: true,
      );
    }

    provider.addListener(listener);
    try {
      await provider.syncCustomSaveFolder(system, emulatorSlug);
    } finally {
      provider.removeListener(listener);
    }
    return (uploaded: provider.uploadedFiles, upToDate: provider.skippedFiles);
  }

  /// Hands the upload to the host's [CustomSaveFoldersView.uploadSystemSaves],
  /// which reports no progress along the way.
  Future<SaveFolderUploadCounts?> _uploadWith(
    Future<SaveFolderUploadCounts?> Function(String system) upload,
    String system,
    String folderLabel,
  ) {
    _showUpload(
      _uploadingMessage(folderLabel),
      custom.NotificationType.info,
      ongoing: true,
    );
    return upload(system);
  }

  Future<void> _removeFolder(String system, String emulatorSlug) async {
    await NeoSyncSaveFolderRepository.removeFolder(system, emulatorSlug);
    await _loadConfigured();
  }

  /// Opens the configure dialog, which does nothing while a folder is
  /// uploading, like the footer's Configure. With [editing], the dialog starts
  /// filled in with that configured folder, and what it saves replaces it.
  ///
  /// The dialog registers its own navigation layer, and popping that layer is
  /// what hands the controller back here. Reactivating this navigator when the
  /// dialog's future completes instead would wake it under the folder picker
  /// the dialog hands over to, and both would act on the same press.
  void _openConfigDialog({(String, String, String)? editing}) {
    if (_syncing) return;
    _gamepadNav.deactivate();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => CustomSaveFoldersDialog(
        systems: _systems,
        emulatorsBySystem: _emulatorsBySystem,
        editing: editing,
        onSelectFolder: (system, slug) =>
            _selectFolderFor(system, slug, replacing: editing),
      ),
    );
  }

  /// A edits the highlighted configured folder, or configures a new one when
  /// there is none.
  void _editFocusedFolder() {
    if (_configured.isEmpty) {
      _openConfigDialog();
      return;
    }
    _openConfigDialog(editing: _configured[_selectedFolderIndex]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _syncing;

    return Padding(
      padding: EdgeInsets.only(top: 52.r, left: 8.r, right: 8.r, bottom: 8.r),
      child: Column(
        children: [
          NeoSyncSectionHeader(
            icon: Symbols.folder_special_rounded,
            title: AppLocale.customSaveFoldersTitle.getString(context),
            subtitle: AppLocale.customFoldersSubtitle.getString(context),
            trailing: Container(
              padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 2.r),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondary,
                borderRadius: BorderRadius.circular(6.r),
              ),
              child: Text(
                AppLocale.foldersConfigured
                    .getString(context)
                    .replaceFirst('{count}', '${_configured.length}'),
                style: TextStyle(
                  fontSize: 8.r,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSecondary,
                ),
              ),
            ),
          ),
          SizedBox(height: 8.r),
          Expanded(
            child: Container(
              padding: EdgeInsets.all(12.r),
              decoration: BoxDecoration(
                color: theme.cardColor.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.15),
                  width: 1.r,
                ),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: 8.r),
                    Text(
                      AppLocale.customSaveFolderConfiguredList.getString(
                        context,
                      ),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: 11.r,
                      ),
                    ),
                    SizedBox(height: 6.r),
                    if (_configured.isEmpty)
                      Padding(
                        padding: EdgeInsets.all(12.r),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(
                                Symbols.folder_special_rounded,
                                size: 40.r,
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.4,
                                ),
                              ),
                              SizedBox(height: 8.r),
                              Text(
                                AppLocale.noCustomFoldersConfigured.getString(
                                  context,
                                ),
                                style: TextStyle(
                                  fontSize: 12.r,
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      for (var i = 0; i < _configured.length; i++) ...[
                        GestureDetector(
                          key: _folderKeys[i],
                          // A tap highlights the row, as the D-pad does, and
                          // a tap on the highlighted row edits it, as A does.
                          onTap: () {
                            if (i == _selectedFolderIndex) {
                              _editFocusedFolder();
                            } else {
                              setState(() => _selectedFolderIndex = i);
                            }
                          },
                          child: Padding(
                            padding: EdgeInsets.only(bottom: 6.r),
                            child: Container(
                              padding: EdgeInsets.all(8.r),
                              decoration: BoxDecoration(
                                color: i == _selectedFolderIndex
                                    ? theme.colorScheme.secondary.withValues(
                                        alpha: 0.12,
                                      )
                                    : theme.colorScheme.primary.withValues(
                                        alpha: 0.05,
                                      ),
                                borderRadius: BorderRadius.circular(8.r),
                                border: Border.all(
                                  color: i == _selectedFolderIndex
                                      ? theme.colorScheme.secondary.withValues(
                                          alpha: 0.6,
                                        )
                                      : theme.colorScheme.primary.withValues(
                                          alpha: 0.15,
                                        ),
                                  width: i == _selectedFolderIndex ? 2.r : 1.r,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _folderHeading(
                                            _configured[i].$1,
                                            _configured[i].$2,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 10.r,
                                              ),
                                        ),
                                        SizedBox(height: 2.r),
                                        Text(
                                          _configured[i].$3,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                fontSize: 9.r,
                                                fontFamily: 'monospace',
                                                color: theme
                                                    .colorScheme
                                                    .onSurface
                                                    .withValues(alpha: 0.7),
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                  ],
                ),
              ),
            ),
          ),
          SizedBox(height: 6.r),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (_configured.isNotEmpty) ...[
                GamepadControl(
                  label: AppLocale.edit.getString(context),
                  iconPath: 'assets/images/gamepad/Xbox_A_button.png',
                  onTap: busy ? null : _editFocusedFolder,
                  textColor: theme.colorScheme.onPrimary,
                  backgroundColor: theme.colorScheme.primary,
                ),
                SizedBox(width: 8.r),
              ],
              GamepadControl(
                label: AppLocale.customSaveFolderConfigure.getString(context),
                iconPath: 'assets/images/gamepad/Xbox_Y_button.png',
                onTap: busy ? null : () => _openConfigDialog(),
                textColor: theme.colorScheme.onTertiaryFixed,
                backgroundColor: theme.colorScheme.tertiaryFixed,
              ),
              SizedBox(width: 8.r),
              GamepadControl(
                label: AppLocale.delete.getString(context),
                iconPath: 'assets/images/gamepad/Xbox_View_button.png',
                onTap: busy ? null : () => _handleSelectFolder(),
                textColor: theme.colorScheme.onError,
                backgroundColor: theme.colorScheme.error,
              ),
              SizedBox(width: 8.r),
              NeoSyncBackButton(onTap: () => widget.onBack()),
            ],
          ),
        ],
      ),
    );
  }
}
