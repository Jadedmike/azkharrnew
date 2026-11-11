import 'package:adhan/adhan.dart';
import 'package:flutter/material.dart';

import '../../../../config/theme/app_colors.dart';
import '../../../../shared/widgets/app_background.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/screen_header.dart';
import '../../data/models/prayer_notification_settings.dart';
import '../../data/models/prayer_settings.dart';
import '../../data/services/prayer_notification_service.dart';
import '../../data/services/prayer_notification_settings_service.dart';
import '../../data/services/prayer_settings_service.dart';

/// Dedicated Prayer Calculation & Notification Settings Screen.
///
/// Manages Phase 2 calculation preferences ([PrayerSettingsService]) and
/// Phase 5 local prayer notifications ([PrayerNotificationSettingsService] +
/// [PrayerNotificationService]) independently of Adhkar `SettingsManager`.
class PrayerSettingsPage extends StatefulWidget {
  final PrayerSettingsService? settingsService;
  final PrayerNotificationSettingsService? notificationSettingsService;
  final PrayerNotificationService? notificationService;

  /// Optional coordinates already acquired during the active session (e.g.,
  /// from [PrayerTimesPage]). Used when enabling notifications so the user can
  /// immediately receive a 7-day schedule without an extra GPS prompt.
  final double? initialLatitude;
  final double? initialLongitude;

  const PrayerSettingsPage({
    super.key,
    this.settingsService,
    this.notificationSettingsService,
    this.notificationService,
    this.initialLatitude,
    this.initialLongitude,
  });

  @override
  State<PrayerSettingsPage> createState() => _PrayerSettingsPageState();
}

class _PrayerSettingsPageState extends State<PrayerSettingsPage>
    with WidgetsBindingObserver {
  late final PrayerSettingsService _settingsService;
  late final PrayerNotificationSettingsService _notificationSettingsService;
  late final PrayerNotificationService _notificationService;

  bool _isLoading = true;
  bool _permissionGranted = true;
  bool _hasCachedCoordinates = false;
  PrayerSettings _prayerSettings = const PrayerSettings.defaults();
  PrayerNotificationSettings _notificationSettings =
      const PrayerNotificationSettings.defaults();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settingsService = widget.settingsService ?? PrayerSettingsService();
    _notificationSettingsService =
        widget.notificationSettingsService ??
        PrayerNotificationSettingsService();
    _notificationService =
        widget.notificationService ??
        PrayerNotificationService(
          prayerSettingsService: _settingsService,
          notificationSettingsService: _notificationSettingsService,
        );

    _loadInitialState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissionAndSyncOnResume();
    }
  }

  Future<void> _loadInitialState() async {
    final loadedPrayerSettings = await _settingsService.loadSettings();
    final loadedNotifSettings =
        await _notificationSettingsService.loadSettings();
    final bool osGranted = await _notificationService.isPermissionGranted();
    final cachedCoords = await _notificationSettingsService
        .loadLastCoordinates();

    final bool hasSessionCoords =
        widget.initialLatitude != null && widget.initialLongitude != null;

    if (!mounted) return;
    setState(() {
      _prayerSettings = loadedPrayerSettings;
      _notificationSettings = loadedNotifSettings;
      _permissionGranted = osGranted;
      _hasCachedCoordinates = cachedCoords != null || hasSessionCoords;
      _isLoading = false;
    });
  }

  Future<void> _refreshPermissionAndSyncOnResume() async {
    final bool osGranted = await _notificationService.isPermissionGranted();
    final cachedCoords = await _notificationSettingsService
        .loadLastCoordinates();
    final bool hasCoords =
        cachedCoords != null ||
        (widget.initialLatitude != null && widget.initialLongitude != null);

    if (!mounted) return;
    setState(() {
      _permissionGranted = osGranted;
      _hasCachedCoordinates = hasCoords;
    });

    if (_notificationSettings.enabled && osGranted && hasCoords) {
      await _notificationService.reschedule(
        notificationSettings: _notificationSettings,
        prayerSettings: _prayerSettings,
        latitude: widget.initialLatitude,
        longitude: widget.initialLongitude,
      );
    }
  }

  Future<void> _rescheduleIfEnabled() async {
    if (!_notificationSettings.enabled) return;

    bool cacheWriteFailed = false;
    if (widget.initialLatitude != null && widget.initialLongitude != null) {
      try {
        await _notificationSettingsService.saveLastCoordinates(
          latitude: widget.initialLatitude!,
          longitude: widget.initialLongitude!,
        );
      } on PrayerNotificationSettingsStorageException {
        cacheWriteFailed = true;
      }
    }

    final result = await _notificationService.reschedule(
      notificationSettings: _notificationSettings,
      prayerSettings: _prayerSettings,
      latitude: cacheWriteFailed ? null : widget.initialLatitude,
      longitude: cacheWriteFailed ? null : widget.initialLongitude,
    );

    final cached = await _notificationSettingsService.loadLastCoordinates();
    if (!mounted) return;
    if (cacheWriteFailed) {
      _showErrorSnackBar(
        'تعذّر حفظ إحداثيات الموقع محلياً لجدولة تنبيهات الصلاة',
      );
    }
    setState(() {
      _permissionGranted = result.permissionGranted;
      _hasCachedCoordinates =
          cached != null ||
          (!cacheWriteFailed &&
              !result.missingCoordinates &&
              widget.initialLatitude != null &&
              widget.initialLongitude != null);
    });
  }

  Future<void> _updateCalculationMode(PrayerCalculationMode mode) async {
    try {
      final updated = await _settingsService.updateCalculationMode(mode);
      if (!mounted) return;
      setState(() => _prayerSettings = updated);
      await _rescheduleIfEnabled();
    } on PrayerSettingsStorageException {
      _showErrorSnackBar('تعذّر حفظ وضع حساب مواقيت الصلاة');
    }
  }

  Future<void> _updateManualMethod(CalculationMethod method) async {
    try {
      final updated = await _settingsService.updateManualCalculationMethod(
        method,
      );
      if (!mounted) return;
      setState(() => _prayerSettings = updated);
      await _rescheduleIfEnabled();
    } on PrayerSettingsStorageException {
      _showErrorSnackBar('تعذّر حفظ طريقة الحساب المختارة');
    }
  }

  Future<void> _updateMadhab(Madhab madhab) async {
    try {
      final updated = await _settingsService.updateMadhab(madhab);
      if (!mounted) return;
      setState(() => _prayerSettings = updated);
      await _rescheduleIfEnabled();
    } on PrayerSettingsStorageException {
      _showErrorSnackBar('تعذّر حفظ المذهب الفقهي');
    }
  }

  Future<void> _handleMasterNotificationToggle(bool value) async {
    if (!value) {
      try {
        final updated = await _notificationSettingsService.updateEnabled(false);
        await _notificationService.cancelAllPrayerNotifications();
        if (!mounted) return;
        setState(() {
          _notificationSettings = updated;
          _hasCachedCoordinates =
              widget.initialLatitude != null && widget.initialLongitude != null;
        });
      } on PrayerNotificationSettingsStorageException {
        _showErrorSnackBar('تعذّر حفظ إعدادات تنبيهات الصلاة');
      }
      return;
    }

    // Read-only check first so we only ask OS permission after an explicit
    // explanation and user confirmation.
    bool granted = await _notificationService.isPermissionGranted();
    if (!granted) {
      if (!mounted) return;
      final bool confirmed = await _showPermissionRationaleDialog();
      if (!confirmed || !mounted) {
        return;
      }
      granted = await _notificationService.requestPermission();
    }

    if (!mounted) return;
    if (!granted) {
      setState(() => _permissionGranted = false);
      await _notificationService.cancelAllPrayerNotifications();
      _showErrorSnackBar(
        'لم يتم منح إذن الإشعارات. يمكنك تفعيله من إعدادات الجهاز لتصلك تنبيهات الصلاة.',
      );
      return;
    }

    try {
      final updated = await _notificationSettingsService.updateEnabled(true);
      if (!mounted) return;
      setState(() {
        _notificationSettings = updated;
        _permissionGranted = true;
      });
      await _rescheduleIfEnabled();
    } on PrayerNotificationSettingsStorageException {
      _showErrorSnackBar('تعذّر حفظ تفعيل تنبيهات الصلاة');
    }
  }

  Future<void> _updatePrayerToggle(Prayer prayer, bool value) async {
    try {
      final updated = await _notificationSettingsService.updatePrayerEnabled(
        prayer,
        value,
      );
      if (!mounted) return;
      setState(() => _notificationSettings = updated);
      await _rescheduleIfEnabled();
    } on PrayerNotificationSettingsStorageException {
      _showErrorSnackBar('تعذّر حفظ تنبيه الصلاة');
    }
  }

  Future<void> _updateSoundMode(PrayerNotificationSound mode) async {
    try {
      final updated = await _notificationSettingsService.updateSoundMode(mode);
      if (!mounted) return;
      setState(() => _notificationSettings = updated);
      await _rescheduleIfEnabled();
    } on PrayerNotificationSettingsStorageException {
      _showErrorSnackBar('تعذّر حفظ خيار صوت التنبيه');
    }
  }

  Future<bool> _showPermissionRationaleDialog() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            backgroundColor: isDark
                ? const Color(0xFF262D24)
                : const Color(0xFFFFFDF9),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: BorderSide(
                color: isDark
                    ? const Color(0xFF353E32)
                    : const Color(0xFFEADFCF),
              ),
            ),
            title: Text(
              'إذن تنبيهات مواقيت الصلاة',
              style: TextStyle(
                fontFamily: 'Fustat',
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isDark
                    ? const Color(0xFFF6F1E7)
                    : AppColors.primaryLight,
              ),
            ),
            content: Text(
              'يحتاج التطبيق إلى إذن الإشعارات لجدولة تنبيهات الصلوات الخمس محلياً على جهازك فقط، مع إمكانية اختيار نغمة تنبيه قصيرة أو الوضع الصامت لكل صلاة.',
              style: TextStyle(
                fontFamily: 'Fustat',
                fontSize: 14,
                height: 1.6,
                color: isDark
                    ? const Color(0xFFD8CEBE)
                    : const Color(0xFF4E5B4E),
              ),
            ),
            actions: [
              TextButton(
                key: const Key('permission_rationale_cancel'),
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(
                  'إلغاء',
                  style: TextStyle(
                    fontFamily: 'Fustat',
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? const Color(0xFFD8CEBE)
                        : const Color(0xFF707973),
                  ),
                ),
              ),
              TextButton(
                key: const Key('permission_rationale_confirm'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(
                  'متابعة',
                  style: TextStyle(
                    fontFamily: 'Fustat',
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? const Color(0xFFC9A15B)
                        : AppColors.primaryLight,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    return result ?? false;
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(
            fontFamily: 'Fustat',
            fontSize: 13.5,
            fontWeight: FontWeight.bold,
            color: Color(0xFFFFFDF9),
          ),
        ),
        backgroundColor: const Color(0xFFC94A4A),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? AppColors.backgroundDark
        : AppColors.backgroundLight;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: bgColor,
        body: Stack(
          children: [
            const AppBackground(),
            SafeArea(
              bottom: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(
                          left: 18,
                          right: 18,
                          top: 14,
                          bottom: 36,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildHeader(context),
                            const SizedBox(height: 20),
                            if (_isLoading)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 48),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            else ...[
                              _buildCalculationSection(context),
                              const SizedBox(height: 20),
                              _buildNotificationsSection(context),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ScreenHeader(
      title: 'إعدادات الصلاة',
      subtitle: 'طريقة الحساب والمذهب وتنبيهات الصلوات الخمس',
      trailing: Navigator.of(context).canPop()
          ? InkWell(
              key: const Key('prayer_settings_back_button'),
              onTap: () => Navigator.of(context).pop(),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF262D24)
                      : const Color(0xFFFFFDF9),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF353E32)
                        : const Color(0xFFEADFCF),
                    width: 1.2,
                  ),
                ),
                child: Icon(
                  Icons.arrow_back_ios_new_rounded,
                  size: 18,
                  color: isDark
                      ? const Color(0xFFD8CEBE)
                      : const Color(0xFF4E5B4E),
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildCalculationSection(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dividerColor = isDark
        ? const Color(0xFF353E32)
        : const Color(0xFFF3ECE0);

    return _buildSectionCard(
      context,
      title: 'إعدادات حساب المواقيت',
      children: [
        _buildSegmentedOptionRow<PrayerCalculationMode>(
          context,
          icon: Icons.compass_calibration_outlined,
          title: 'وضع الحساب',
          value: _prayerSettings.calculationMode,
          options: const <PrayerCalculationMode, String>{
            PrayerCalculationMode.auto: 'تلقائي',
            PrayerCalculationMode.manual: 'يدوي',
          },
          keyPrefix: 'calc_mode',
          onChanged: _updateCalculationMode,
        ),
        const SizedBox(height: 10),
        if (_prayerSettings.calculationMode == PrayerCalculationMode.auto)
          _buildInfoBanner(
            context,
            key: const Key('auto_mode_fallback_note'),
            icon: Icons.info_outline_rounded,
            text:
                'يعتمد الوضع التلقائي على طريقة رابطة العالم الإسلامي كخيار افتراضي عند عدم توفر رمز الدولة، ولا يقوم بالكشف التلقائي عن الدولة.',
          )
        else ...[
          Divider(height: 22, color: dividerColor),
          _buildMethodDropdownRow(context),
        ],
        Divider(height: 22, color: dividerColor),
        _buildSegmentedOptionRow<Madhab>(
          context,
          icon: Icons.balance_rounded,
          title: 'المذهب (صلاة العصر)',
          value: _prayerSettings.madhab,
          options: const <Madhab, String>{
            Madhab.shafi: 'الشافعي',
            Madhab.hanafi: 'الحنفي',
          },
          keyPrefix: 'madhab',
          onChanged: _updateMadhab,
        ),
      ],
    );
  }

  Widget _buildNotificationsSection(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dividerColor = isDark
        ? const Color(0xFF353E32)
        : const Color(0xFFF3ECE0);

    return _buildSectionCard(
      context,
      title: 'تنبيهات الصلوات الخمس',
      children: [
        _buildSwitchRow(
          context,
          switchKey: const Key('prayer_notifications_master_switch'),
          icon: Icons.notifications_none_rounded,
          title: 'تفعيل تنبيهات الصلاة',
          subtitle: 'تشمل الصلوات الخمس المفروضة فقط (لا تشمل الشروق)',
          value: _notificationSettings.enabled,
          onChanged: _handleMasterNotificationToggle,
        ),
        if (!_permissionGranted) ...[
          const SizedBox(height: 12),
          _buildPermissionDeniedBanner(context),
        ],
        if (_notificationSettings.enabled && !_hasCachedCoordinates) ...[
          const SizedBox(height: 12),
          _buildInfoBanner(
            context,
            key: const Key('missing_coordinates_note'),
            icon: Icons.location_off_outlined,
            text:
                'يرجى فتح شاشة مواقيت الصلاة وتحديد موقعك الحالي لحساب أوقات الصلاة وجدولة التنبيهات تلقائياً.',
          ),
        ],
        if (_notificationSettings.enabled) ...[
          Divider(height: 22, color: dividerColor),
          _buildSegmentedOptionRow<PrayerNotificationSound>(
            context,
            icon: Icons.volume_up_outlined,
            title: 'صوت التنبيه',
            value: _notificationSettings.soundMode,
            options: const <PrayerNotificationSound, String>{
              PrayerNotificationSound.short: 'صوت قصير',
              PrayerNotificationSound.silent: 'صامت',
            },
            keyPrefix: 'sound_mode',
            onChanged: _updateSoundMode,
          ),
          Divider(height: 22, color: dividerColor),
          for (
            int i = 0;
            i < PrayerNotificationSettings.eligiblePrayers.length;
            i++
          ) ...[
            if (i > 0) Divider(height: 18, color: dividerColor),
            _buildPrayerSwitchRow(
              context,
              PrayerNotificationSettings.eligiblePrayers[i],
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildPrayerSwitchRow(BuildContext context, Prayer prayer) {
    final IconData icon;
    switch (prayer) {
      case Prayer.fajr:
        icon = Icons.wb_twilight_rounded;
        break;
      case Prayer.dhuhr:
        icon = Icons.light_mode_rounded;
        break;
      case Prayer.asr:
        icon = Icons.wb_cloudy_outlined;
        break;
      case Prayer.maghrib:
        icon = Icons.nights_stay_outlined;
        break;
      case Prayer.isha:
        icon = Icons.bedtime_outlined;
        break;
      case Prayer.sunrise:
      case Prayer.none:
        return const SizedBox.shrink();
    }

    return _buildSwitchRow(
      context,
      switchKey: Key('prayer_toggle_${prayer.name}'),
      icon: icon,
      title: PrayerNotificationService.prayerNameAr(prayer),
      value: _notificationSettings.isPrayerEnabled(prayer),
      onChanged: (val) => _updatePrayerToggle(prayer, val),
    );
  }

  Widget _buildSectionCard(
    BuildContext context, {
    required String title,
    required List<Widget> children,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 6, bottom: 8),
          child: Text(
            title,
            style: TextStyle(
              fontFamily: 'Fustat',
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: isDark ? const Color(0xFFC9A15B) : const Color(0xFF4E5B4E),
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isDark ? const Color(0xFF353E32) : const Color(0xFFF3ECE0),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? const Color(0x20000000)
                    : const Color(0x0A000000),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }

  Widget _buildMethodDropdownRow(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _buildIconBadge(context, Icons.menu_book_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'طريقة الحساب اليدوية',
                style: TextStyle(
                  fontFamily: 'Fustat',
                  fontSize: 14.5,
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? const Color(0xFFF6F1E7)
                      : const Color(0xFF1E281F),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1F241D) : const Color(0xFFF7F2E8),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark ? const Color(0xFF353E32) : const Color(0xFFEADFCF),
            ),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<CalculationMethod>(
              key: const Key('manual_calculation_method_dropdown'),
              isExpanded: true,
              value: _prayerSettings.manualCalculationMethod,
              dropdownColor: isDark
                  ? const Color(0xFF1F241D)
                  : const Color(0xFFFFFDF9),
              icon: Icon(
                Icons.keyboard_arrow_down_rounded,
                color: isDark
                    ? const Color(0xFFC9A15B)
                    : const Color(0xFF4E5B4E),
              ),
              style: TextStyle(
                fontFamily: 'Fustat',
                fontSize: 13.5,
                fontWeight: FontWeight.bold,
                color: isDark
                    ? const Color(0xFFF6F1E7)
                    : const Color(0xFF1E281F),
              ),
              onChanged: (method) {
                if (method != null) {
                  _updateManualMethod(method);
                }
              },
              items: PrayerSettings.supportedCalculationMethods.map((method) {
                return DropdownMenuItem<CalculationMethod>(
                  value: method,
                  child: Text(
                    _calculationMethodLabelAr(method),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Fustat',
                      fontSize: 13.5,
                      color: isDark
                          ? const Color(0xFFF6F1E7)
                          : const Color(0xFF1E281F),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSegmentedOptionRow<T>(
    BuildContext context, {
    required IconData icon,
    required String title,
    required T value,
    required Map<T, String> options,
    required String keyPrefix,
    required ValueChanged<T> onChanged,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Row(
            children: [
              _buildIconBadge(context, icon),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'Fustat',
                    fontSize: 14.5,
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? const Color(0xFFF6F1E7)
                        : const Color(0xFF1E281F),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Wrap(
          spacing: 6,
          children: options.entries.map((entry) {
            final bool selected = entry.key == value;
            final String optionName = entry.key is Enum
                ? (entry.key as Enum).name
                : entry.value;
            return InkWell(
              key: Key('${keyPrefix}_$optionName'),
              onTap: () => onChanged(entry.key),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? (isDark
                            ? const Color(0xFFC9A15B)
                            : AppColors.primaryLight)
                      : (isDark
                            ? const Color(0xFF1F241D)
                            : const Color(0xFFF7F2E8)),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected
                        ? Colors.transparent
                        : (isDark
                              ? const Color(0xFF353E32)
                              : const Color(0xFFEADFCF)),
                  ),
                ),
                child: Text(
                  entry.value,
                  style: TextStyle(
                    fontFamily: 'Fustat',
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: selected
                        ? (isDark ? const Color(0xFF1E281F) : Colors.white)
                        : (isDark
                              ? const Color(0xFFD8CEBE)
                              : const Color(0xFF4E5B4E)),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildSwitchRow(
    BuildContext context, {
    required Key switchKey,
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Row(
            children: [
              _buildIconBadge(context, icon),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontFamily: 'Fustat',
                        fontSize: 14.5,
                        fontWeight: FontWeight.bold,
                        color: isDark
                            ? const Color(0xFFF6F1E7)
                            : const Color(0xFF1E281F),
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontFamily: 'Fustat',
                          fontSize: 11.5,
                          color: isDark
                              ? const Color(0xFFD8CEBE)
                              : const Color(0xFF707973),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        Switch(
          key: switchKey,
          value: value,
          activeThumbColor: isDark
              ? const Color(0xFFC9A15B)
              : const Color(0xFF4E5B4E),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildIconBadge(BuildContext context, IconData icon) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F241D) : const Color(0xFFF7F2E8),
        shape: BoxShape.circle,
        border: Border.all(
          color: isDark ? const Color(0xFF353E32) : const Color(0xFFEADFCF),
          width: 1,
        ),
      ),
      child: Icon(
        icon,
        size: 20,
        color: isDark ? const Color(0xFFC9A15B) : const Color(0xFF4E5B4E),
      ),
    );
  }

  Widget _buildInfoBanner(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String text,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F241D) : const Color(0xFFF7F2E8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF353E32) : const Color(0xFFEADFCF),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 18,
            color: isDark ? const Color(0xFFC9A15B) : const Color(0xFF4E5B4E),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontFamily: 'Fustat',
                fontSize: 12,
                height: 1.5,
                color: isDark
                    ? const Color(0xFFD8CEBE)
                    : const Color(0xFF4E5B4E),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionDeniedBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: const Key('permission_denied_banner'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF2D2220)
            : const Color(0xFFFDF2F0),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? const Color(0xFF6B3E3A)
              : const Color(0xFFE6B8B3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'إذن الإشعارات غير مفعّل في النظام',
            style: TextStyle(
              fontFamily: 'Fustat',
              fontSize: 13.5,
              fontWeight: FontWeight.bold,
              color: isDark
                  ? const Color(0xFFF6D5D1)
                  : const Color(0xFF9C3029),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'تم تعطيل الإشعارات على مستوى النظام، لذا لن يتم جدولة أي تنبيه للصلاة حتى يتم منح الإذن.',
            style: TextStyle(
              fontFamily: 'Fustat',
              fontSize: 12,
              height: 1.5,
              color: isDark
                  ? const Color(0xFFD8CEBE)
                  : const Color(0xFF5C4442),
            ),
          ),
          const SizedBox(height: 10),
          AppButton(
            key: const Key('open_device_settings_button'),
            text: 'فتح إعدادات الجهاز',
            variant: AppButtonVariant.secondary,
            height: 42,
            icon: const Icon(Icons.settings_outlined, size: 17),
            onPressed: _notificationService.openAppSettings,
          ),
        ],
      ),
    );
  }

  static String _calculationMethodLabelAr(CalculationMethod method) {
    switch (method) {
      case CalculationMethod.muslim_world_league:
        return 'رابطة العالم الإسلامي';
      case CalculationMethod.umm_al_qura:
        return 'أم القرى';
      case CalculationMethod.egyptian:
        return 'الهيئة المصرية العامة للمساحة';
      case CalculationMethod.karachi:
        return 'جامعة العلوم الإسلامية بكراتشي';
      case CalculationMethod.dubai:
        return 'دبي';
      case CalculationMethod.kuwait:
        return 'الكويت';
      case CalculationMethod.qatar:
        return 'قطر';
      case CalculationMethod.singapore:
        return 'سنغافورة (MABIMS)';
      case CalculationMethod.turkey:
        return 'رئاسة الشؤون الدينية التركية';
      case CalculationMethod.tehran:
        return 'طهران';
      case CalculationMethod.north_america:
        return 'أمريكا الشمالية (ISNA)';
      case CalculationMethod.moon_sighting_committee:
        return 'لجنة تحري الهلال';
      case CalculationMethod.other:
        return 'مخصص';
    }
  }
}

