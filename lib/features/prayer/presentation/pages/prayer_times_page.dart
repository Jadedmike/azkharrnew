import 'dart:async';

import 'package:adhan/adhan.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hijri/hijri_calendar.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../../../config/theme/app_assets.dart';
import '../../../../config/theme/app_colors.dart';
import '../../../../config/theme/app_page_transitions.dart';
import '../../../../shared/widgets/app_background.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/floating_bottom_nav_bar.dart';
import '../../../../shared/widgets/screen_header.dart';
import '../../data/models/prayer_settings.dart';
import '../../data/models/prayer_times_result.dart';
import '../../data/models/saved_prayer_location.dart';
import '../../data/services/prayer_calculation_service.dart';
import '../../data/services/prayer_geocoding_service.dart';
import '../../data/services/prayer_location_cache_service.dart';
import '../../data/services/prayer_location_service.dart';
import '../../data/services/prayer_notification_service.dart';
import '../../data/services/prayer_notification_settings_service.dart';
import '../../data/services/prayer_settings_service.dart';
import 'prayer_settings_page.dart';

/// UI state categories for [PrayerTimesPage].
enum _PrayerScreenState {
  loading,
  permissionDenied,
  permissionDeniedForever,
  locationServiceDisabled,
  locationUnavailable,
  calculationFailure,
  success,
}

/// Metadata descriptor for each of the six daily prayer-related times.
class _PrayerEntry {
  final Prayer prayer;
  final String nameAr;
  final IconData icon;
  final DateTime time;

  const _PrayerEntry({
    required this.prayer,
    required this.nameAr,
    required this.icon,
    required this.time,
  });
}

/// Dedicated Prayer Times Screen ("مواقيت الصلاة") for the ADKHAR_APP ("ذِكْر").
///
/// Connects Phase 2 [PrayerSettingsService] and Phase 3
/// [PrayerLocationService] + [PrayerCalculationService] while preserving the
/// existing warm-beige/dark-olive Islamic visual identity and RTL conventions.
class PrayerTimesPage extends StatefulWidget {
  /// Optional injected [PrayerSettingsService] (used for testing or custom DI).
  final PrayerSettingsService? settingsService;

  /// Optional injected [PrayerLocationService] (used for testing or custom DI).
  final PrayerLocationService? locationService;

  /// Optional injected [PrayerCalculationService] (used for testing or custom DI).
  final PrayerCalculationService? calculationService;

  /// Optional clock provider returning the current local [DateTime].
  final DateTime Function()? clock;

  /// Optional injected [PrayerNotificationSettingsService].
  final PrayerNotificationSettingsService? notificationSettingsService;

  /// Optional injected [PrayerNotificationService].
  final PrayerNotificationService? notificationService;

  /// Optional injected [PrayerLocationCacheService].
  final PrayerLocationCacheService? locationCacheService;

  /// Optional injected [PrayerGeocodingService].
  final PrayerGeocodingService? geocodingService;

  const PrayerTimesPage({
    super.key,
    this.settingsService,
    this.locationService,
    this.calculationService,
    this.clock,
    this.notificationSettingsService,
    this.notificationService,
    this.locationCacheService,
    this.geocodingService,
  });

  @override
  State<PrayerTimesPage> createState() => _PrayerTimesPageState();
}

class _PrayerTimesPageState extends State<PrayerTimesPage>
    with WidgetsBindingObserver {
  late final PrayerSettingsService _settingsService;
  late final PrayerLocationService _locationService;
  late final PrayerCalculationService _calculationService;
  late final PrayerNotificationSettingsService _notificationSettingsService;
  late final PrayerNotificationService _notificationService;
  late final PrayerLocationCacheService _locationCacheService;
  late final PrayerGeocodingService _geocodingService;
  late final DateTime Function() _clock;

  _PrayerScreenState _screenState = _PrayerScreenState.loading;
  PrayerSettings _settings = const PrayerSettings.defaults();
  bool _hasLoadedSettings = false;
  bool _isRefreshingLocation = false;

  SavedPrayerLocation? _savedLocation;
  PrayerTimesResult? _prayerTimesResult;
  DateTime? _tomorrowFajr;
  String? _errorTitle;
  String? _errorMessage;

  Timer? _countdownTimer;
  DateTime _now = DateTime.now().toLocal();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settingsService = widget.settingsService ?? PrayerSettingsService();
    _locationService = widget.locationService ?? const PrayerLocationService();
    _calculationService =
        widget.calculationService ?? const PrayerCalculationService();
    _notificationSettingsService =
        widget.notificationSettingsService ??
        PrayerNotificationSettingsService();
    _notificationService =
        widget.notificationService ??
        PrayerNotificationService(
          calculationService: _calculationService,
          prayerSettingsService: _settingsService,
          notificationSettingsService: _notificationSettingsService,
          clock: widget.clock,
        );
    _locationCacheService =
        widget.locationCacheService ?? PrayerLocationCacheService();
    _geocodingService =
        widget.geocodingService ?? const PrayerGeocodingService();
    _clock = widget.clock ?? DateTime.now;
    _now = _clock().toLocal();

    _initializePrayerTimes();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final resumedNow = _clock().toLocal();
      final result = _prayerTimesResult;
      if (_savedLocation != null &&
          result != null &&
          (resumedNow.year != result.year ||
              resumedNow.month != result.month ||
              resumedNow.day != result.day)) {
        _calculateForCurrentCoordinates();
        return;
      }
      unawaited(
        _notificationService.syncFromPersistedState(
          latitude: _savedLocation?.latitude,
          longitude: _savedLocation?.longitude,
          onlyIfDateOrTimezoneChanged: true,
        ),
      );
    }
  }

  /// Loads user settings (once), reuses a persisted saved location when
  /// available without invoking GPS or geocoding, or acquires and caches a
  /// fresh foreground location on demand, then calculates today's prayer times.
  Future<void> _initializePrayerTimes({
    bool requestPermissionIfNeeded = true,
  }) async {
    final bool wasPermanentlyDenied =
        _screenState == _PrayerScreenState.permissionDeniedForever;
    _countdownTimer?.cancel();
    setState(() {
      _screenState = _PrayerScreenState.loading;
      _errorTitle = null;
      _errorMessage = null;
    });

    // 1. Load persisted PrayerSettings only if not already loaded
    if (!_hasLoadedSettings) {
      final loaded = await _settingsService.loadSettings();
      if (!mounted) return;
      _settings = loaded;
      _hasLoadedSettings = true;
    }

    // 2. Load persisted SavedPrayerLocation first (never calls GPS/geocoding if valid)
    if (_savedLocation == null) {
      final cached = await _locationCacheService.loadLocation();
      if (!mounted) return;
      if (cached != null && cached.isValid) {
        _savedLocation = cached;
      }
    }

    // 3. Acquire foreground coordinates + reverse geocode + persist if not saved yet
    if (_savedLocation == null) {
      final acquisition = await _acquireAndBuildLocation(
        requestPermissionIfNeeded: requestPermissionIfNeeded,
        wasPermanentlyDenied: wasPermanentlyDenied,
      );
      if (!mounted) return;

      if (acquisition.failureReason != null || acquisition.location == null) {
        _applyLocationFailure(
          acquisition.failureReason ??
              PrayerLocationFailureReason.positionUnavailable,
        );
        return;
      }

      final candidate = acquisition.location!;
      try {
        _savedLocation = await _locationCacheService.saveLocation(candidate);
      } on PrayerLocationCacheStorageException {
        // Keep valid in-memory location for current session even if disk write fails.
        _savedLocation = candidate;
      }
      if (!mounted) return;
    }

    // 4. Calculate prayer times for current saved location and device-local date
    _calculateForCurrentCoordinates();
  }

  /// Acquires foreground coordinates and enriches them with reverse-geocoded
  /// administrative address fields (falling back safely if geocoding fails).
  Future<
    ({
      SavedPrayerLocation? location,
      PrayerLocationFailureReason? failureReason,
    })
  >
  _acquireAndBuildLocation({
    required bool requestPermissionIfNeeded,
    required bool wasPermanentlyDenied,
  }) async {
    final locationResult = await _locationService.getCurrentLocation(
      requestPermissionIfNeeded: requestPermissionIfNeeded,
    );

    if (locationResult.isFailure || locationResult.coordinates == null) {
      PrayerLocationFailureReason failureReason =
          locationResult.failureReason ??
          PrayerLocationFailureReason.positionUnavailable;
      // Android checkPermission() returns `denied` rather than `deniedForever`;
      // preserve the prior permanent-denial state when retrying without prompting.
      if (wasPermanentlyDenied &&
          failureReason == PrayerLocationFailureReason.permissionDenied) {
        failureReason = PrayerLocationFailureReason.permissionDeniedForever;
      }
      if (kDebugMode) {
        final Object? cause = locationResult.cause;
        final String causeDetails = cause is PlatformException
            ? 'code=${cause.code}, message=${cause.message}'
            : (locationResult.errorMessage ?? '');
        debugPrint(
          '[PrayerTimesPage] Location failed: '
          'reason=${failureReason.name}, '
          'exceptionType=${cause?.runtimeType}, '
          'details=$causeDetails',
        );
      }
      return (location: null, failureReason: failureReason);
    }

    final coords = locationResult.coordinates!;
    final address = await _geocodingService.reverseGeocode(
      latitude: coords.latitude,
      longitude: coords.longitude,
    );

    final savedLocation = SavedPrayerLocation(
      latitude: coords.latitude,
      longitude: coords.longitude,
      timestamp: coords.timestamp,
      countryIsoCode: address.countryIsoCode,
      countryName: address.countryName,
      city: address.city,
      district: address.district,
      source: coords.isCached
          ? PrayerLocationSource.cached
          : PrayerLocationSource.fresh,
    );

    if (kDebugMode) {
      debugPrint(
        '[PrayerTimesPage] Location acquired: '
        'source=${coords.isCached ? 'cached' : 'fresh'}, '
        'timestamp=${coords.timestamp.toIso8601String()}',
      );
    }
    return (location: savedLocation, failureReason: null);
  }

  /// Explicitly refreshes GPS + address while keeping the previously saved
  /// valid location intact if acquisition or persistence fails.
  Future<void> _handleManualLocationRefresh() async {
    if (_isRefreshingLocation) return;
    final previousLocation = _savedLocation;
    if (previousLocation == null) {
      await _initializePrayerTimes();
      return;
    }

    setState(() {
      _isRefreshingLocation = true;
    });

    final acquisition = await _acquireAndBuildLocation(
      requestPermissionIfNeeded: true,
      wasPermanentlyDenied: false,
    );
    if (!mounted) return;

    if (acquisition.failureReason != null || acquisition.location == null) {
      setState(() {
        _isRefreshingLocation = false;
      });
      _showRefreshPreservedSnackBar();
      return;
    }

    SavedPrayerLocation updated;
    try {
      updated = await _locationCacheService.saveLocation(acquisition.location!);
    } on PrayerLocationCacheStorageException {
      if (!mounted) return;
      setState(() {
        _savedLocation = previousLocation;
        _isRefreshingLocation = false;
      });
      _showRefreshPreservedSnackBar();
      return;
    }

    if (!mounted) return;
    setState(() {
      _savedLocation = updated;
      _isRefreshingLocation = false;
    });
    _calculateForCurrentCoordinates();
  }

  void _showRefreshPreservedSnackBar() {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      const SnackBar(
        content: Text(
          'تعذّر تحديث الموقع، تم الإبقاء على الموقع المحفوظ',
          style: TextStyle(fontFamily: 'Fustat'),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Retries only the failed step without overwriting user settings or
  /// repeating already-completed initialization.
  Future<void> _handleRetry() async {
    if (_screenState == _PrayerScreenState.calculationFailure &&
        _savedLocation != null) {
      setState(() {
        _screenState = _PrayerScreenState.loading;
        _errorTitle = null;
        _errorMessage = null;
      });
      _calculateForCurrentCoordinates();
      return;
    }

    // If permission was permanently denied, check current permission status
    // without repeatedly prompting the system dialog.
    final bool shouldPromptPermission =
        _screenState != _PrayerScreenState.permissionDeniedForever;

    await _initializePrayerTimes(
      requestPermissionIfNeeded: shouldPromptPermission,
    );
  }

  void _applyLocationFailure(PrayerLocationFailureReason reason) {
    switch (reason) {
      case PrayerLocationFailureReason.serviceDisabled:
        setState(() {
          _screenState = _PrayerScreenState.locationServiceDisabled;
          _errorTitle = 'خدمات الموقع غير مفعّلة';
          _errorMessage =
              'يرجى تفعيل خدمات الموقع في جهازك لحساب مواقيت الصلاة بدقة حسب موقعك الحالي.';
        });
        break;
      case PrayerLocationFailureReason.permissionDenied:
        setState(() {
          _screenState = _PrayerScreenState.permissionDenied;
          _errorTitle = 'يلزم إذن الوصول إلى الموقع';
          _errorMessage =
              'يحتاج التطبيق إلى إذن الوصول إلى الموقع الجغرافي لحساب مواقيت الصلاة بدقة.';
        });
        break;
      case PrayerLocationFailureReason.permissionDeniedForever:
        setState(() {
          _screenState = _PrayerScreenState.permissionDeniedForever;
          _errorTitle = 'تم رفض إذن الموقع بشكل دائم';
          _errorMessage =
              'تم حجب إذن الوصول إلى الموقع بشكل دائم. يرجى تفعيله من إعدادات النظام ثم الضغط على إعادة المحاولة.';
        });
        break;
      case PrayerLocationFailureReason.timeout:
        setState(() {
          _screenState = _PrayerScreenState.locationUnavailable;
          _errorTitle = 'انتهت مهلة تحديد الموقع';
          _errorMessage =
              'تعذّر الحصول على الموقع الحالي في الوقت المحدد. يرجى التحقق من الإشارة والمحاولة مرة أخرى.';
        });
        break;
      case PrayerLocationFailureReason.positionUnavailable:
      case PrayerLocationFailureReason.platformFailure:
        setState(() {
          _screenState = _PrayerScreenState.locationUnavailable;
          _errorTitle = 'تعذّر تحديد الموقع الحالي';
          _errorMessage =
              'الموقع غير متاح حالياً. يرجى المحاولة مرة أخرى لحساب مواقيت الصلاة.';
        });
        break;
    }
  }

  void _calculateForCurrentCoordinates() {
    final savedLocation = _savedLocation;
    if (savedLocation == null || !savedLocation.isValid) {
      _applyLocationFailure(PrayerLocationFailureReason.positionUnavailable);
      return;
    }

    final currentMoment = _clock().toLocal();
    try {
      final result = _calculationService.calculate(
        latitude: savedLocation.latitude,
        longitude: savedLocation.longitude,
        date: currentMoment,
        settings: _settings,
        countryCode: savedLocation.countryIsoCode,
      );

      final tomorrowDate = DateTime(
        currentMoment.year,
        currentMoment.month,
        currentMoment.day + 1,
      );
      final tomorrowResult = _calculationService.tryCalculate(
        latitude: savedLocation.latitude,
        longitude: savedLocation.longitude,
        date: tomorrowDate,
        settings: _settings,
        countryCode: savedLocation.countryIsoCode,
      );

      if (!mounted) return;
      setState(() {
        _now = currentMoment;
        _prayerTimesResult = result;
        _tomorrowFajr = tomorrowResult?.fajr.toLocal();
        _screenState = _PrayerScreenState.success;
        _errorTitle = null;
        _errorMessage = null;
      });
      _startCountdownTimer();
      unawaited(
        _notificationService.onCoordinatesUpdated(
          latitude: savedLocation.latitude,
          longitude: savedLocation.longitude,
          prayerSettings: _settings,
        ),
      );
    } on PrayerCalculationException {
      if (!mounted) return;
      setState(() {
        _screenState = _PrayerScreenState.calculationFailure;
        _errorTitle = 'تعذّر حساب مواقيت الصلاة';
        _errorMessage =
            'تعذّر حساب مواقيت الصلاة للموقع والتاريخ الحاليين. يرجى المحاولة مرة أخرى.';
      });
    }
  }

  void _startCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final tickNow = _clock().toLocal();
      final result = _prayerTimesResult;
      if (result != null &&
          (tickNow.year != result.year ||
              tickNow.month != result.month ||
              tickNow.day != result.day)) {
        _calculateForCurrentCoordinates();
        return;
      }
      setState(() {
        _now = tickNow;
      });
    });
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
                          bottom: 105,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildHeader(context),
                            const SizedBox(height: 16),
                            _buildDateAndMetadataCard(context),
                            const SizedBox(height: 16),
                            _buildBodyContent(context),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16 + MediaQuery.of(context).padding.bottom,
              child: const FloatingBottomNavBar(selectedIndex: 2),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openPrayerSettings() async {
    await Navigator.of(context).push(
      AppPageRoute.create(
        PrayerSettingsPage(
          settingsService: _settingsService,
          notificationSettingsService: _notificationSettingsService,
          notificationService: _notificationService,
          initialLatitude: _savedLocation?.latitude,
          initialLongitude: _savedLocation?.longitude,
        ),
      ),
    );
    if (!mounted) return;
    final refreshedSettings = await _settingsService.loadSettings();
    if (!mounted) return;
    setState(() {
      _settings = refreshedSettings;
    });
    if (_savedLocation != null) {
      _calculateForCurrentCoordinates();
    }
  }

  Widget _buildHeader(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ScreenHeader(
      title: 'مواقيت الصلاة',
      subtitle: 'حسب موقعك الحالي والإعدادات المختارة',
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeaderIconButton(
            context,
            buttonKey: const Key('prayer_settings_button'),
            icon: Icons.tune_rounded,
            iconSize: 20,
            color: isDark ? const Color(0xFFC9A15B) : const Color(0xFF4E5B4E),
            onTap: _openPrayerSettings,
          ),
          if (_screenState == _PrayerScreenState.success) ...[
            const SizedBox(width: 8),
            _buildHeaderIconButton(
              context,
              buttonKey: const Key('prayer_refresh_button'),
              icon: Icons.refresh_rounded,
              iconSize: 20,
              color: isDark ? const Color(0xFFC9A15B) : const Color(0xFF4E5B4E),
              isBusy: _isRefreshingLocation,
              onTap: _handleManualLocationRefresh,
            ),
          ],
        ],
      ),
      trailing: Navigator.of(context).canPop()
          ? _buildHeaderIconButton(
              context,
              icon: Icons.arrow_back_ios_new_rounded,
              iconSize: 18,
              color: isDark ? const Color(0xFFD8CEBE) : const Color(0xFF4E5B4E),
              onTap: () => Navigator.of(context).pop(),
            )
          : null,
    );
  }

  Widget _buildHeaderIconButton(
    BuildContext context, {
    Key? buttonKey,
    required IconData icon,
    required double iconSize,
    required Color color,
    required VoidCallback onTap,
    bool isBusy = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      key: buttonKey,
      onTap: isBusy ? null : onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? const Color(0xFF353E32) : const Color(0xFFEADFCF),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: isDark ? const Color(0x20000000) : const Color(0x0A000000),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: isBusy
            ? Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                ),
              )
            : Icon(icon, size: iconSize, color: color),
      ),
    );
  }

  Widget _buildDateAndMetadataCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveMethod =
        _prayerTimesResult?.calculationMethod ??
        _settingsService.resolveEffectiveCalculationMethod(
          countryCode: _savedLocation?.countryIsoCode,
        );
    final modeLabel = _settings.calculationMode == PrayerCalculationMode.auto
        ? 'تلقائي'
        : 'يدوي';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark ? const Color(0xFF353E32) : const Color(0xFFEADFCF),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? const Color(0x20000000) : const Color(0x0A000000),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Date Row
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF1F241D)
                      : const Color(0xFFF7F2E8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.calendar_month_outlined,
                  color: isDark
                      ? const Color(0xFFC9A15B)
                      : const Color(0xFFC5A059),
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatHijriDate(_now),
                      style: TextStyle(
                        fontFamily: 'Fustat',
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                        color: isDark
                            ? const Color(0xFFF6F1E7)
                            : AppColors.primaryLight,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatGregorianDate(_now),
                      style: TextStyle(
                        fontFamily: 'Fustat',
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: isDark
                            ? const Color(0xFFD8CEBE)
                            : const Color(0xFF707973),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          Divider(
            height: 22,
            color: isDark ? const Color(0xFF353E32) : const Color(0xFFF3ECE0),
          ),

          // Location status row (human-readable city/district/country or generic label; never shows raw coordinates)
          Row(
            children: [
              Icon(
                _savedLocation != null
                    ? Icons.location_on_outlined
                    : Icons.location_off_outlined,
                size: 18,
                color: isDark
                    ? const Color(0xFFC9A15B)
                    : const Color(0xFF4E5B4E),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _savedLocation != null
                      ? 'الموقع: ${_savedLocation!.displayName}'
                      : 'الموقع غير متاح',
                  style: TextStyle(
                    fontFamily: 'Fustat',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? const Color(0xFFF6F1E7)
                        : const Color(0xFF1E281F),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Calculation Method & Madhab pills
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildMetadataChip(
                context,
                icon: Icons.compass_calibration_outlined,
                label:
                    'طريقة الحساب: ${_calculationMethodLabelAr(effectiveMethod)} ($modeLabel)',
              ),
              _buildMetadataChip(
                context,
                icon: Icons.balance_rounded,
                label: 'المذهب: ${_madhabLabelAr(_settings.madhab)}',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataChip(
    BuildContext context, {
    required IconData icon,
    required String label,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F241D) : const Color(0xFFF7F2E8),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF353E32) : const Color(0xFFEADFCF),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: isDark ? const Color(0xFFC9A15B) : const Color(0xFF4E5B4E),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Fustat',
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
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

  Widget _buildBodyContent(BuildContext context) {
    switch (_screenState) {
      case _PrayerScreenState.loading:
        return _buildLoadingState(context);
      case _PrayerScreenState.permissionDenied:
      case _PrayerScreenState.permissionDeniedForever:
      case _PrayerScreenState.locationServiceDisabled:
      case _PrayerScreenState.locationUnavailable:
      case _PrayerScreenState.calculationFailure:
        return _buildStatusMessageState(context);
      case _PrayerScreenState.success:
        final result = _prayerTimesResult;
        if (result == null) {
          return _buildStatusMessageState(context);
        }
        return _buildSuccessState(context, result);
    }
  }

  Widget _buildLoadingState(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 44),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark ? const Color(0xFF353E32) : const Color(0xFFF3ECE0),
          width: 1.2,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(
            color: isDark ? const Color(0xFFC9A15B) : AppColors.primaryLight,
            strokeWidth: 3,
          ),
          const SizedBox(height: 18),
          Text(
            'جاري تحديد الموقع وحساب مواقيت الصلاة...',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Fustat',
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isDark ? const Color(0xFFF6F1E7) : AppColors.primaryLight,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusMessageState(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    IconData stateIcon;
    switch (_screenState) {
      case _PrayerScreenState.locationServiceDisabled:
        stateIcon = Icons.location_disabled_rounded;
        break;
      case _PrayerScreenState.permissionDenied:
      case _PrayerScreenState.permissionDeniedForever:
        stateIcon = Icons.location_off_outlined;
        break;
      case _PrayerScreenState.calculationFailure:
        stateIcon = Icons.error_outline_rounded;
        break;
      default:
        stateIcon = Icons.my_location_rounded;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: isDark ? const Color(0xFF353E32) : const Color(0xFFF3ECE0),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? const Color(0x20000000) : const Color(0x0A000000),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1F241D) : const Color(0xFFF7F2E8),
              shape: BoxShape.circle,
              border: Border.all(
                color: isDark
                    ? const Color(0xFF353E32)
                    : const Color(0xFFEADFCF),
                width: 1.5,
              ),
            ),
            child: Icon(
              stateIcon,
              size: 32,
              color: isDark ? const Color(0xFFC9A15B) : const Color(0xFFC5A059),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            _errorTitle ?? 'تعذّر تحميل مواقيت الصلاة',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Fustat',
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: isDark ? const Color(0xFFF6F1E7) : AppColors.primaryLight,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _errorMessage ?? 'يرجى المحاولة مرة أخرى.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Fustat',
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: isDark ? const Color(0xFFD8CEBE) : const Color(0xFF707973),
              height: 1.6,
            ),
          ),
          const SizedBox(height: 22),
          AppButton(
            text: 'إعادة المحاولة',
            icon: const Icon(Icons.refresh_rounded, size: 18),
            onPressed: _handleRetry,
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessState(BuildContext context, PrayerTimesResult result) {
    final entries = <_PrayerEntry>[
      _PrayerEntry(
        prayer: Prayer.fajr,
        nameAr: 'الفجر',
        icon: Icons.wb_twilight_rounded,
        time: result.fajr,
      ),
      _PrayerEntry(
        prayer: Prayer.sunrise,
        nameAr: 'الشروق',
        icon: Icons.wb_sunny_outlined,
        time: result.sunrise,
      ),
      _PrayerEntry(
        prayer: Prayer.dhuhr,
        nameAr: 'الظهر',
        icon: Icons.light_mode_rounded,
        time: result.dhuhr,
      ),
      _PrayerEntry(
        prayer: Prayer.asr,
        nameAr: 'العصر',
        icon: Icons.wb_cloudy_outlined,
        time: result.asr,
      ),
      _PrayerEntry(
        prayer: Prayer.maghrib,
        nameAr: 'المغرب',
        icon: Icons.nights_stay_outlined,
        time: result.maghrib,
      ),
      _PrayerEntry(
        prayer: Prayer.isha,
        nameAr: 'العشاء',
        icon: Icons.bedtime_outlined,
        time: result.isha,
      ),
    ];

    final upcomingInfo = _resolveUpcomingAndCurrent(entries);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (upcomingInfo.nextEntry != null) ...[
          _buildNextPrayerHighlightCard(
            context,
            nextEntry: upcomingInfo.nextEntry!,
            remaining: upcomingInfo.remaining,
          ),
          const SizedBox(height: 16),
        ],
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: entries.length,
          separatorBuilder: (context, index) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final entry = entries[index];
            final isNext = upcomingInfo.nextHighlightPrayer == entry.prayer;
            final isCurrent = upcomingInfo.currentPrayer == entry.prayer;
            return _buildPrayerRowCard(
              context,
              entry: entry,
              isNext: isNext,
              isCurrent: isCurrent,
            );
          },
        ),
      ],
    );
  }

  Widget _buildNextPrayerHighlightCard(
    BuildContext context, {
    required _PrayerEntry nextEntry,
    required Duration? remaining,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark ? const Color(0xFFC9A15B) : const Color(0xFFC5A059),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? const Color(0x28000000) : const Color(0x12000000),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            right: 0,
            top: 0,
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(24),
              ),
              child: Opacity(
                opacity: 0.16,
                child: Image.asset(
                  AppAssets.oliveBranches,
                  width: 85,
                  height: 85,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF1F241D)
                            : const Color(0xFFF7F2E8),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.schedule_rounded,
                            size: 15,
                            color: isDark
                                ? const Color(0xFFC9A15B)
                                : const Color(0xFFC5A059),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'الصلاة القادمة',
                            style: TextStyle(
                              fontFamily: 'Fustat',
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? const Color(0xFFC9A15B)
                                  : const Color(0xFF4E5B4E),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      _formatTime12Hour(nextEntry.time),
                      style: TextStyle(
                        fontFamily: 'Fustat',
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isDark
                            ? const Color(0xFFC9A15B)
                            : const Color(0xFF4E5B4E),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      children: [
                        Icon(
                          nextEntry.icon,
                          size: 26,
                          color: isDark
                              ? const Color(0xFFC9A15B)
                              : AppColors.primaryLight,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          nextEntry.nameAr,
                          style: TextStyle(
                            fontFamily: 'Fustat',
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: isDark
                                ? const Color(0xFFF6F1E7)
                                : const Color(0xFF1E281F),
                          ),
                        ),
                      ],
                    ),
                    if (remaining != null)
                      Container(
                        key: const Key('next_prayer_countdown'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF1F241D)
                              : const Color(0xFFF0E8DA),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          'متبقي ${_formatCountdown(remaining)}',
                          style: TextStyle(
                            fontFamily: 'Fustat',
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: isDark
                                ? const Color(0xFFF6F1E7)
                                : AppColors.primaryLight,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrayerRowCard(
    BuildContext context, {
    required _PrayerEntry entry,
    required bool isNext,
    required bool isCurrent,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color borderColor = isNext
        ? (isDark ? const Color(0xFFC9A15B) : const Color(0xFFC5A059))
        : (isDark ? const Color(0xFF353E32) : const Color(0xFFF3ECE0));
    final Color cardBgColor = isNext
        ? (isDark ? const Color(0xFF2E362C) : const Color(0xFFFAF5EA))
        : (isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9));

    return Container(
      key: Key('prayer_row_${entry.prayer.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: cardBgColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: borderColor,
          width: isNext ? 1.6 : 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? const Color(0x20000000) : const Color(0x0A000000),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF1F241D)
                      : const Color(0xFFF7F2E8),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF353E32)
                        : const Color(0xFFEADFCF),
                    width: 1,
                  ),
                ),
                child: Icon(
                  entry.icon,
                  size: 20,
                  color: isNext
                      ? (isDark
                            ? const Color(0xFFC9A15B)
                            : const Color(0xFFC5A059))
                      : (isDark
                            ? const Color(0xFFD8CEBE)
                            : const Color(0xFF4E5B4E)),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                entry.nameAr,
                style: TextStyle(
                  fontFamily: 'Fustat',
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? const Color(0xFFF6F1E7)
                      : const Color(0xFF1E281F),
                ),
              ),
              if (isNext || isCurrent) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: isNext
                        ? (isDark
                              ? const Color(0xFFC9A15B)
                              : const Color(0xFFC5A059))
                        : (isDark
                              ? const Color(0xFF1F241D)
                              : const Color(0xFFEADFCF)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    isNext ? 'القادمة' : 'الحالية',
                    style: TextStyle(
                      fontFamily: 'Fustat',
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      color: isNext
                          ? const Color(0xFF1E281F)
                          : (isDark
                                ? const Color(0xFFD8CEBE)
                                : const Color(0xFF4E5B4E)),
                    ),
                  ),
                ),
              ],
            ],
          ),
          Text(
            _formatTime12Hour(entry.time),
            style: TextStyle(
              fontFamily: 'Fustat',
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: isNext
                  ? (isDark
                        ? const Color(0xFFC9A15B)
                        : AppColors.primaryLight)
                  : (isDark
                        ? const Color(0xFFF6F1E7)
                        : const Color(0xFF1E281F)),
            ),
          ),
        ],
      ),
    );
  }

  /// Resolves the current active obligatory prayer, the next upcoming
  /// obligatory prayer, and the remaining countdown duration relative to [_now].
  ///
  /// Sunrise ([Prayer.sunrise]) remains visible in the daily schedule but is
  /// never treated as a current or upcoming obligatory prayer:
  /// - Before Fajr: `currentPrayer == null`, `nextPrayer == Prayer.fajr`
  /// - Fajr -> Sunrise: `currentPrayer == Prayer.fajr`, `nextPrayer == Prayer.dhuhr`
  /// - Sunrise -> Dhuhr: `currentPrayer == null`, `nextPrayer == Prayer.dhuhr`
  /// - Dhuhr -> Asr -> Maghrib -> Isha: standard obligatory progression
  /// - After Isha: `currentPrayer == Prayer.isha`, `nextPrayer` is tomorrow's Fajr
  ({
    Prayer? currentPrayer,
    Prayer? nextHighlightPrayer,
    _PrayerEntry? nextEntry,
    Duration? remaining,
  }) _resolveUpcomingAndCurrent(List<_PrayerEntry> entries) {
    DateTime? sunriseTime;
    final obligatoryEntries = <_PrayerEntry>[];
    for (final entry in entries) {
      if (entry.prayer == Prayer.sunrise) {
        sunriseTime = entry.time;
      } else {
        obligatoryEntries.add(entry);
      }
    }

    for (int i = 0; i < obligatoryEntries.length; i++) {
      final entry = obligatoryEntries[i];
      if (entry.time.isAfter(_now)) {
        Prayer? current;
        if (i > 0) {
          final previousObligatory = obligatoryEntries[i - 1];
          if (previousObligatory.prayer == Prayer.fajr &&
              sunriseTime != null &&
              !_now.isBefore(sunriseTime)) {
            current = null;
          } else {
            current = previousObligatory.prayer;
          }
        }
        return (
          currentPrayer: current,
          nextHighlightPrayer: entry.prayer,
          nextEntry: entry,
          remaining: entry.time.difference(_now),
        );
      }
    }

    // All obligatory prayers for today have passed (after Isha):
    // Current prayer is Isha, and next upcoming prayer is tomorrow's Fajr if available.
    if (_tomorrowFajr != null && _tomorrowFajr!.isAfter(_now)) {
      return (
        currentPrayer: Prayer.isha,
        nextHighlightPrayer: Prayer.fajr,
        nextEntry: _PrayerEntry(
          prayer: Prayer.fajr,
          nameAr: 'الفجر',
          icon: Icons.wb_twilight_rounded,
          time: _tomorrowFajr!,
        ),
        remaining: _tomorrowFajr!.difference(_now),
      );
    }

    return (
      currentPrayer: Prayer.isha,
      nextHighlightPrayer: null,
      nextEntry: null,
      remaining: null,
    );
  }

  static String _formatTime12Hour(DateTime dateTime) {
    final local = dateTime.toLocal();
    final int hour24 = local.hour;
    final int minute = local.minute;
    final String period = hour24 >= 12 ? 'م' : 'ص';
    final int hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final String hh = hour12.toString().padLeft(2, '0');
    final String mm = minute.toString().padLeft(2, '0');
    return '$hh:$mm $period';
  }

  static String _formatCountdown(Duration duration) {
    final int totalSeconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    final String hh = hours.toString().padLeft(2, '0');
    final String mm = minutes.toString().padLeft(2, '0');
    final String ss = seconds.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
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

  static String _madhabLabelAr(Madhab madhab) {
    switch (madhab) {
      case Madhab.shafi:
        return 'الشافعي (الجمهور)';
      case Madhab.hanafi:
        return 'الحنفي';
    }
  }

  static String _formatHijriDate(DateTime date) {
    try {
      HijriCalendar.setLocal('ar');
      final hDate = HijriCalendar.fromDate(date);
      String weekdayName;
      try {
        weekdayName = DateFormat('EEEE', 'ar').format(date);
      } catch (_) {
        const weekdaysAr = [
          'الإثنين',
          'الثلاثاء',
          'الأربعاء',
          'الخميس',
          'الجمعة',
          'السبت',
          'الأحد',
        ];
        weekdayName = weekdaysAr[date.weekday - 1];
      }
      return '$weekdayName ${hDate.hDay} ${hDate.longMonthName} ${hDate.hYear} هـ';
    } catch (_) {
      return '';
    }
  }

  static String _formatGregorianDate(DateTime date) {
    try {
      String formatted;
      try {
        formatted = DateFormat('d MMMM yyyy', 'ar').format(date);
      } catch (_) {
        const monthsAr = [
          'يناير',
          'فبراير',
          'مارس',
          'أبريل',
          'مايو',
          'يونيو',
          'يوليو',
          'أغسطس',
          'سبتمبر',
          'أكتوبر',
          'نوفمبر',
          'ديسمبر',
        ];
        formatted = '${date.day} ${monthsAr[date.month - 1]} ${date.year}';
      }
      return '$formatted م';
    } catch (_) {
      return '${date.day}/${date.month}/${date.year} م';
    }
  }
}

