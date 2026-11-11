import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../config/theme/app_colors.dart';
import '../../../../shared/widgets/app_background.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/floating_bottom_nav_bar.dart';
import '../../../../shared/widgets/screen_header.dart';
import '../../../prayer/data/models/saved_prayer_location.dart';
import '../../../prayer/data/services/prayer_location_cache_service.dart';
import '../../../prayer/data/services/prayer_location_service.dart';
import '../../data/services/magnetic_declination_service.dart';
import '../../data/services/qibla_calculation_service.dart';
import '../../data/services/qibla_compass_service.dart';

/// Location resolution stages for [QiblaPage].
enum _QiblaLocationState { loading, missingLocation, ready }

/// Compass sensor states for [QiblaPage].
enum _QiblaSensorState { initializing, active, unavailable }

/// Dedicated Qibla Compass screen ("اتجاه القبلة") reusing Phase 5.5
/// [PrayerLocationCacheService] and [flutter_compass] hardware heading events.
class QiblaPage extends StatefulWidget {
  final PrayerLocationCacheService? locationCacheService;
  final PrayerLocationService? locationService;
  final QiblaCompassService? compassService;
  final QiblaCalculationService? calculationService;
  final MagneticDeclinationService? declinationService;
  final DateTime Function()? clock;

  /// Bounded wait time before treating a silent compass stream as unavailable.
  final Duration sensorAvailabilityTimeout;

  const QiblaPage({
    super.key,
    this.locationCacheService,
    this.locationService,
    this.compassService,
    this.calculationService,
    this.declinationService,
    this.clock,
    this.sensorAvailabilityTimeout = const Duration(seconds: 3),
  });

  @override
  State<QiblaPage> createState() => _QiblaPageState();
}

class _QiblaPageState extends State<QiblaPage> {
  static const double _alignmentToleranceDegrees = 5.0;

  late final PrayerLocationCacheService _locationCacheService;
  late final PrayerLocationService _locationService;
  late final QiblaCompassService _compassService;
  late final QiblaCalculationService _calculationService;
  late final MagneticDeclinationService _declinationService;
  late final DateTime Function() _clock;

  _QiblaLocationState _locationState = _QiblaLocationState.loading;
  _QiblaSensorState _sensorState = _QiblaSensorState.initializing;

  SavedPrayerLocation? _savedLocation;
  QiblaCalculationResult? _qiblaResult;
  MagneticDeclinationResult? _declinationResult;
  String? _declinationErrorMessage;

  double? _smoothedHeading;
  bool _needsCalibration = false;
  bool _showCalibrationTip = false;
  bool _hasNullHeadingNotice = false;
  bool _isUpdatingLocation = false;
  String? _locationErrorTitle;
  String? _locationErrorMessage;

  StreamSubscription<QiblaCompassReading>? _compassSubscription;
  Timer? _sensorTimeoutTimer;

  @override
  void initState() {
    super.initState();
    _locationCacheService =
        widget.locationCacheService ?? PrayerLocationCacheService();
    _locationService = widget.locationService ?? const PrayerLocationService();
    _compassService = widget.compassService ?? const QiblaCompassService();
    _calculationService =
        widget.calculationService ?? const QiblaCalculationService();
    _declinationService =
        widget.declinationService ?? const MagneticDeclinationService();
    _clock = widget.clock ?? DateTime.now;

    _loadSavedLocationOnly();
  }

  @override
  void dispose() {
    _cancelCompassSubscription();
    super.dispose();
  }

  /// Loads cached location strictly without calling GPS or reverse geocoding.
  Future<void> _loadSavedLocationOnly() async {
    setState(() {
      _locationState = _QiblaLocationState.loading;
      _locationErrorTitle = null;
      _locationErrorMessage = null;
    });

    final SavedPrayerLocation? cached = await _locationCacheService
        .loadLocation();
    if (!mounted) return;

    if (cached == null || !cached.isValid) {
      setState(() {
        _savedLocation = null;
        _qiblaResult = null;
        _locationState = _QiblaLocationState.missingLocation;
      });
      return;
    }

    _applyValidLocation(cached);
  }

  void _applyValidLocation(SavedPrayerLocation location) {
    final result = _calculationService.tryCalculateBearing(
      latitude: location.latitude,
      longitude: location.longitude,
    );
    if (result == null) {
      setState(() {
        _savedLocation = null;
        _qiblaResult = null;
        _declinationResult = null;
        _declinationErrorMessage = null;
        _locationState = _QiblaLocationState.missingLocation;
      });
      return;
    }

    MagneticDeclinationResult? computedDeclination;
    String? declinationError;

    // Android (`magneticNorth`) requires WMM-2025 geomagnetic declination to
    // convert raw magnetic compass azimuths into True North. iOS already
    // supplies True North via CLHeading.trueHeading and must not be offset twice.
    if (_compassService.headingReference ==
        QiblaHeadingReference.magneticNorth) {
      try {
        computedDeclination = _declinationService.calculate(
          latitude: location.latitude,
          longitude: location.longitude,
          date: _clock(),
        );
      } on MagneticDeclinationException catch (error) {
        declinationError = error.type == MagneticDeclinationErrorType.unsupportedDate
            ? 'نموذج الانحراف المغناطيسي (WMM-2025) يدعم التواريخ بين عامي 2025 و 2029 فقط. تعذّر تصحيح قراءات البوصلة لتاريخ الجهاز الحالي.'
            : 'تعذّر حساب الانحراف المغناطيسي للموقع والتاريخ الحاليين، لذا تم إيقاف مؤشر البوصلة الحية لتفادي قراءة غير دقيقة.';
      } catch (_) {
        declinationError =
            'تعذّر حساب الانحراف المغناطيسي للموقع والتاريخ الحاليين، لذا تم إيقاف مؤشر البوصلة الحية لتفادي قراءة غير دقيقة.';
      }
    }

    if (declinationError != null) {
      _cancelCompassSubscription();
      setState(() {
        _savedLocation = location;
        _qiblaResult = result;
        _declinationResult = null;
        _declinationErrorMessage = declinationError;
        _smoothedHeading = null;
        _locationState = _QiblaLocationState.ready;
        _sensorState = _QiblaSensorState.unavailable;
        _locationErrorTitle = null;
        _locationErrorMessage = null;
      });
      return;
    }

    setState(() {
      _savedLocation = location;
      _qiblaResult = result;
      _declinationResult = computedDeclination;
      _declinationErrorMessage = null;
      _smoothedHeading = null;
      _locationState = _QiblaLocationState.ready;
      _locationErrorTitle = null;
      _locationErrorMessage = null;
    });
    _ensureCompassSubscription();
  }

  /// Explicitly acquires GPS coordinates only when requested by the user,
  /// never performs reverse geocoding, and preserves any previously saved
  /// valid location if acquisition or storage fails.
  Future<void> _acquireLocationExplicitly() async {
    if (_isUpdatingLocation) return;
    final SavedPrayerLocation? previousLocation = _savedLocation;

    setState(() {
      _isUpdatingLocation = true;
      _locationErrorTitle = null;
      _locationErrorMessage = null;
    });

    final PrayerLocationResult result = await _locationService
        .getCurrentLocation(requestPermissionIfNeeded: true);
    if (!mounted) return;

    if (result.isFailure || result.coordinates == null) {
      _handleLocationAcquisitionFailure(
        previousLocation: previousLocation,
        reason:
            result.failureReason ??
            PrayerLocationFailureReason.positionUnavailable,
      );
      return;
    }

    final PrayerCoordinates coords = result.coordinates!;
    final candidate = SavedPrayerLocation(
      latitude: coords.latitude,
      longitude: coords.longitude,
      timestamp: coords.timestamp,
      source: coords.isCached
          ? PrayerLocationSource.cached
          : PrayerLocationSource.fresh,
    );

    SavedPrayerLocation persisted;
    try {
      persisted = await _locationCacheService.saveLocation(candidate);
    } on PrayerLocationCacheStorageException {
      if (!mounted) return;
      if (previousLocation != null && previousLocation.isValid) {
        setState(() {
          _savedLocation = previousLocation;
          _isUpdatingLocation = false;
        });
        _showInfoSnackBar('تعذّر تحديث الموقع، تم الإبقاء على الموقع المحفوظ');
        return;
      }
      // Even if writing to disk fails, calculate for the session's valid fix.
      setState(() {
        _isUpdatingLocation = false;
      });
      _applyValidLocation(candidate);
      return;
    }

    if (!mounted) return;
    setState(() {
      _isUpdatingLocation = false;
    });
    _applyValidLocation(persisted);
  }

  void _handleLocationAcquisitionFailure({
    required SavedPrayerLocation? previousLocation,
    required PrayerLocationFailureReason reason,
  }) {
    if (previousLocation != null && previousLocation.isValid) {
      setState(() {
        _savedLocation = previousLocation;
        _isUpdatingLocation = false;
      });
      _showInfoSnackBar('تعذّر تحديث الموقع، تم الإبقاء على الموقع المحفوظ');
      return;
    }

    final ({String title, String message}) copy = _locationFailureCopy(reason);
    setState(() {
      _isUpdatingLocation = false;
      _locationState = _QiblaLocationState.missingLocation;
      _locationErrorTitle = copy.title;
      _locationErrorMessage = copy.message;
    });
  }

  ({String title, String message}) _locationFailureCopy(
    PrayerLocationFailureReason reason,
  ) {
    switch (reason) {
      case PrayerLocationFailureReason.serviceDisabled:
        return (
          title: 'خدمات الموقع غير مفعّلة',
          message:
              'يرجى تفعيل خدمات الموقع في جهازك ثم الضغط على زر تحديد الموقع لحساب اتجاه القبلة.',
        );
      case PrayerLocationFailureReason.permissionDenied:
        return (
          title: 'يلزم إذن الوصول إلى الموقع',
          message:
              'يرجى السماح بالوصول إلى الموقع الجغرافي لحساب زاوية القبلة بدقة لموقعك.',
        );
      case PrayerLocationFailureReason.permissionDeniedForever:
        return (
          title: 'تم رفض إذن الموقع بشكل دائم',
          message:
              'تم حجب إذن الموقع بشكل دائم. يرجى تفعيله من إعدادات النظام ثم المحاولة مرة أخرى.',
        );
      case PrayerLocationFailureReason.timeout:
        return (
          title: 'انتهت مهلة تحديد الموقع',
          message:
              'تعذّر الحصول على إحداثيات الموقع في الوقت المحدد. يرجى التحقق من الإشارة والمحاولة مجدداً.',
        );
      case PrayerLocationFailureReason.positionUnavailable:
      case PrayerLocationFailureReason.platformFailure:
        return (
          title: 'تعذّر تحديد الموقع الحالي',
          message:
              'الموقع غير متاح حالياً. يمكنك المحاولة مرة أخرى عندما يتوفر اتصال الموقع.',
        );
    }
  }

  void _ensureCompassSubscription() {
    if (_compassSubscription != null) {
      return;
    }

    final Stream<QiblaCompassReading>? stream = _compassService.readings();
    if (stream == null) {
      setState(() {
        _sensorState = _QiblaSensorState.unavailable;
        _smoothedHeading = null;
      });
      return;
    }

    setState(() {
      _sensorState = _QiblaSensorState.initializing;
      _hasNullHeadingNotice = false;
    });

    _sensorTimeoutTimer?.cancel();
    _sensorTimeoutTimer = Timer(widget.sensorAvailabilityTimeout, () {
      if (!mounted) return;
      if (_sensorState == _QiblaSensorState.initializing &&
          _smoothedHeading == null) {
        _cancelCompassSubscription();
        setState(() {
          _sensorState = _QiblaSensorState.unavailable;
        });
      }
    });

    _compassSubscription = stream.listen(
      _onCompassReading,
      onError: (_) {
        if (!mounted) return;
        _cancelCompassSubscription();
        setState(() {
          _sensorState = _QiblaSensorState.unavailable;
          _smoothedHeading = null;
        });
      },
      onDone: () {
        if (!mounted) return;
        _sensorTimeoutTimer?.cancel();
        _sensorTimeoutTimer = null;
        _compassSubscription = null;
        if (_smoothedHeading == null) {
          setState(() {
            _sensorState = _QiblaSensorState.unavailable;
          });
        }
      },
      cancelOnError: true,
    );
  }

  void _onCompassReading(QiblaCompassReading reading) {
    if (!mounted) return;

    if (!reading.hasValidHeading) {
      if (!_hasNullHeadingNotice ||
          _needsCalibration != reading.needsCalibration) {
        setState(() {
          _hasNullHeadingNotice = true;
          _needsCalibration = reading.needsCalibration;
        });
      }
      return;
    }

    final double trueHeading;
    if (reading.isTrueNorth) {
      // iOS CLHeading.trueHeading is already referenced to True North.
      trueHeading = reading.heading!;
    } else {
      final MagneticDeclinationResult? declination = _declinationResult;
      if (declination == null) {
        // Explicit safety guard: never compare uncorrected magnetic heading
        // directly against a True-North Qibla bearing.
        return;
      }
      trueHeading = QiblaCalculationService.normalizeAngle(
        reading.heading! + declination.declinationDegrees,
      );
    }

    _sensorTimeoutTimer?.cancel();
    _sensorTimeoutTimer = null;

    final double nextSmoothed = _calculationService.smoothHeading(
      previousSmoothed: _smoothedHeading,
      rawHeading: trueHeading,
    );

    final bool headingChanged =
        _smoothedHeading == null ||
        QiblaCalculationService.shortestSignedDelta(
              _smoothedHeading!,
              nextSmoothed,
            ).abs() >=
            0.01;
    final bool stateChanged =
        _sensorState != _QiblaSensorState.active ||
        _needsCalibration != reading.needsCalibration ||
        _hasNullHeadingNotice;

    if (!headingChanged && !stateChanged) {
      return;
    }

    setState(() {
      _sensorState = _QiblaSensorState.active;
      _smoothedHeading = nextSmoothed;
      _needsCalibration = reading.needsCalibration;
      _hasNullHeadingNotice = false;
    });
  }

  void _cancelCompassSubscription() {
    _sensorTimeoutTimer?.cancel();
    _sensorTimeoutTimer = null;
    _compassSubscription?.cancel();
    _compassSubscription = null;
  }

  void _showInfoSnackBar(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(text, style: const TextStyle(fontFamily: 'Fustat')),
        behavior: SnackBarBehavior.floating,
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
                          bottom: 105,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildHeader(context),
                            const SizedBox(height: 16),
                            _buildBody(context),
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

  Widget _buildHeader(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ScreenHeader(
      title: 'اتجاه القبلة',
      subtitle: 'توجيه البوصلة نحو الكعبة المشرفة',
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeaderIconButton(
            context,
            buttonKey: const Key('qibla_calibration_info_button'),
            icon: Icons.info_outline_rounded,
            color: isDark ? const Color(0xFFC9A15B) : const Color(0xFF4E5B4E),
            onTap: () {
              setState(() {
                _showCalibrationTip = !_showCalibrationTip;
              });
            },
          ),
          if (_locationState == _QiblaLocationState.ready) ...[
            const SizedBox(width: 8),
            _buildHeaderIconButton(
              context,
              buttonKey: const Key('qibla_refresh_location_button'),
              icon: Icons.refresh_rounded,
              color: isDark ? const Color(0xFFC9A15B) : const Color(0xFF4E5B4E),
              isBusy: _isUpdatingLocation,
              onTap: _acquireLocationExplicitly,
            ),
          ],
        ],
      ),
      trailing: Navigator.of(context).canPop()
          ? _buildHeaderIconButton(
              context,
              buttonKey: const Key('qibla_back_button'),
              icon: Icons.arrow_back_ios_new_rounded,
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
            : Icon(icon, size: 20, color: color),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_locationState) {
      case _QiblaLocationState.loading:
        return _buildLoadingCard(
          context,
          message: 'جاري استرجاع الموقع المحفوظ...',
        );
      case _QiblaLocationState.missingLocation:
        return _buildMissingLocationCard(context);
      case _QiblaLocationState.ready:
        return _buildReadyContent(context);
    }
  }

  Widget _buildLoadingCard(BuildContext context, {required String message}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      decoration: _cardDecoration(isDark),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(
            color: isDark ? const Color(0xFFC9A15B) : AppColors.primaryLight,
            strokeWidth: 3,
          ),
          const SizedBox(height: 18),
          Text(
            message,
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

  Widget _buildMissingLocationCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final String title = _locationErrorTitle ?? 'الموقع المحفوظ غير متوفر';
    final String message =
        _locationErrorMessage ??
        'لحساب اتجاه القبلة بدقة، يحتاج التطبيق إلى تحديد موقعك الحالي مرة واحدة وحفظه على جهازك.';

    return Container(
      key: const Key('qibla_missing_location_card'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
      decoration: _cardDecoration(isDark),
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
              Icons.location_off_outlined,
              size: 32,
              color: isDark ? const Color(0xFFC9A15B) : const Color(0xFFC5A059),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
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
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Fustat',
              fontSize: 13.5,
              height: 1.6,
              color: isDark ? const Color(0xFFD8CEBE) : const Color(0xFF707973),
            ),
          ),
          const SizedBox(height: 22),
          AppButton(
            key: const Key('qibla_acquire_location_button'),
            text: _isUpdatingLocation
                ? 'جاري تحديد الموقع...'
                : 'تحديد الموقع الآن',
            icon: Icon(
              Icons.my_location_rounded,
              size: 18,
              color: isDark
                  ? AppColors.textPrimaryLight
                  : AppColors.onPrimaryLight,
            ),
            isFullWidth: true,
            onPressed: _isUpdatingLocation ? null : _acquireLocationExplicitly,
          ),
        ],
      ),
    );
  }

  Widget _buildReadyContent(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final SavedPrayerLocation location = _savedLocation!;
    final QiblaCalculationResult result = _qiblaResult!;

    final double? relativeDirection = _smoothedHeading != null
        ? _calculationService.calculateRelativeDirection(
            qiblaBearing: result.bearing,
            deviceHeading: _smoothedHeading!,
          )
        : null;

    final bool isAligned =
        relativeDirection != null &&
        QiblaCalculationService.shortestSignedDelta(
              0.0,
              relativeDirection,
            ).abs() <=
            _alignmentToleranceDegrees;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildLocationSummaryCard(context, location, result),
        if (_needsCalibration || _showCalibrationTip) ...[
          const SizedBox(height: 12),
          _buildCalibrationGuidanceCard(context),
        ],
        const SizedBox(height: 16),
        if (_declinationErrorMessage != null)
          _buildDeclinationErrorCard(context, result, _declinationErrorMessage!)
        else if (_sensorState == _QiblaSensorState.unavailable)
          _buildSensorUnavailableCard(context, result)
        else ...[
          _buildCompassCard(
            context,
            isDark: isDark,
            result: result,
            relativeDirection: relativeDirection,
            isAligned: isAligned,
          ),
        ],
      ],
    );
  }

  Widget _buildLocationSummaryCard(
    BuildContext context,
    SavedPrayerLocation location,
    QiblaCalculationResult result,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.location_on_outlined,
                size: 18,
                color: isDark
                    ? const Color(0xFFC9A15B)
                    : const Color(0xFF4E5B4E),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'الموقع: ${location.displayName}',
                  key: const Key('qibla_location_label'),
                  style: TextStyle(
                    fontFamily: 'Fustat',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? const Color(0xFFF6F1E7)
                        : const Color(0xFF1E281F),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildMetricChip(
                context,
                chipKey: const Key('qibla_bearing_chip'),
                icon: Icons.explore_outlined,
                label:
                    'زاوية القبلة: ${result.bearingDegrees}° (${QiblaCalculationService.cardinalDirectionAr(result.bearing)})',
              ),
              if (_smoothedHeading != null)
                _buildMetricChip(
                  context,
                  chipKey: const Key('qibla_heading_chip'),
                  icon: Icons.compass_calibration_outlined,
                  label:
                      'اتجاه الهاتف: ${QiblaCalculationService.toWholeDegrees(_smoothedHeading!)}°',
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricChip(
    BuildContext context, {
    Key? chipKey,
    required IconData icon,
    required String label,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: chipKey,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                fontSize: 12,
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

  Widget _buildCalibrationGuidanceCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: const Key('qibla_calibration_card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2E362C) : const Color(0xFFFAF5EA),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? const Color(0xFFC9A15B) : const Color(0xFFC5A059),
          width: 1.2,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.screen_rotation_alt_rounded,
            size: 20,
            color: isDark ? const Color(0xFFC9A15B) : const Color(0xFFC5A059),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _needsCalibration
                  ? 'دقة مستشعر البوصلة منخفضة حالياً. حرّك الهاتف بلطف في الهواء على شكل الرقم 8 (∞) وابتعد عن الأجهزة المعدنية.'
                  : 'لأفضل دقة، ضع الهاتف بشكل مسطّح أفقياً وقم بتحريكه على شكل الرقم 8 (∞) لمعايرة البوصلة.',
              style: TextStyle(
                fontFamily: 'Fustat',
                fontSize: 12.5,
                height: 1.5,
                color: isDark
                    ? const Color(0xFFF6F1E7)
                    : const Color(0xFF1E281F),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompassCard(
    BuildContext context, {
    required bool isDark,
    required QiblaCalculationResult result,
    required double? relativeDirection,
    required bool isAligned,
  }) {
    final bool isWaitingForHeading =
        _sensorState == _QiblaSensorState.initializing ||
        relativeDirection == null;

    final Color accentColor = isAligned
        ? AppColors.success
        : (isDark ? const Color(0xFFC9A15B) : const Color(0xFFC5A059));

    return Container(
      key: const Key('qibla_compass_card'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: isAligned
              ? AppColors.success
              : (isDark ? const Color(0xFF353E32) : const Color(0xFFEADFCF)),
          width: isAligned ? 1.8 : 1.3,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? const Color(0x28000000) : const Color(0x10000000),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          if (result.isAtKaaba)
            _buildStatusBadge(
              context,
              label: 'أنت عند المسجد الحرام',
              color: AppColors.success,
            )
          else if (isWaitingForHeading || _hasNullHeadingNotice)
            _buildStatusBadge(
              context,
              label: _hasNullHeadingNotice
                  ? 'بانتظار قراءة مستقرة من المستشعر...'
                  : 'جاري قراءة مستشعر البوصلة...',
              color: isDark ? const Color(0xFFC9A15B) : AppColors.primaryLight,
            )
          else
            _buildStatusBadge(
              context,
              label: isAligned
                  ? 'أنت متجه نحو القبلة'
                  : 'وجّه السهم الذهبي نحو المؤشر العلوي',
              color: accentColor,
            ),
          const SizedBox(height: 18),
          SizedBox(
            width: 260,
            height: 260,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Fixed top alignment notch on the phone frame
                Positioned(
                  top: 0,
                  child: Container(
                    width: 4,
                    height: 14,
                    decoration: BoxDecoration(
                      color: accentColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // Compass rose rotating opposite to device heading so North stays true North
                Transform.rotate(
                  key: const Key('qibla_compass_dial'),
                  angle: _smoothedHeading != null
                      ? -(_smoothedHeading! * math.pi / 180.0)
                      : 0.0,
                  child: CustomPaint(
                    size: const Size(236, 236),
                    painter: _CompassDialPainter(
                      isDark: isDark,
                      ringColor: isDark
                          ? const Color(0xFF353E32)
                          : const Color(0xFFEADFCF),
                      tickColor: isDark
                          ? const Color(0xFFD8CEBE)
                          : const Color(0xFF707973),
                      northColor: AppColors.error,
                      qiblaMarkerAngleDegrees: result.bearing,
                      qiblaMarkerColor: accentColor,
                    ),
                  ),
                ),
                // Dynamic Qibla pointer relative to phone's orientation
                if (!isWaitingForHeading && !result.isAtKaaba)
                  Transform.rotate(
                    key: const Key('qibla_direction_indicator'),
                    angle: relativeDirection * math.pi / 180.0,
                    child: SizedBox(
                      width: 220,
                      height: 220,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Positioned(
                            top: 18,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.navigation_rounded,
                                  size: 38,
                                  color: accentColor,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // Center Kaaba emblem
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDark
                        ? const Color(0xFF1F241D)
                        : const Color(0xFFF7F2E8),
                    border: Border.all(color: accentColor, width: 1.8),
                  ),
                  child: Icon(
                    Icons.mosque_rounded,
                    size: 28,
                    color: accentColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (!isWaitingForHeading)
            Text(
              'الانحراف النسبي عن القبلة: ${QiblaCalculationService.toWholeDegrees(relativeDirection)}°',
              key: const Key('qibla_relative_angle_text'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Fustat',
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? const Color(0xFFD8CEBE)
                    : const Color(0xFF4E5B4E),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(
    BuildContext context, {
    required String label,
    required Color color,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F241D) : const Color(0xFFF7F2E8),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 1),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'Fustat',
          fontSize: 12.5,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Widget _buildDeclinationErrorCard(
    BuildContext context,
    QiblaCalculationResult result,
    String errorMessage,
  ) {
    return _buildStatusFallbackCard(
      context,
      cardKey: const Key('qibla_declination_error_card'),
      icon: Icons.warning_amber_rounded,
      title: 'تعذّر تصحيح الانحراف المغناطيسي',
      body:
          '$errorMessage\n'
          'زاوية القبلة المحسوبة لموقعك هي ${result.bearingDegrees}° (${QiblaCalculationService.cardinalDirectionAr(result.bearing)} من الشمال الحقيقي).',
    );
  }

  Widget _buildSensorUnavailableCard(
    BuildContext context,
    QiblaCalculationResult result,
  ) {
    return _buildStatusFallbackCard(
      context,
      cardKey: const Key('qibla_sensor_unavailable_card'),
      icon: Icons.sensors_off_rounded,
      title: 'مستشعر البوصلة غير متوفر',
      body:
          'لا يدعم هذا الجهاز مستشعر الاتجاه المغناطيسي أو أن المستشعر متوقف حالياً، لذا تعذّر عرض إبرة حية للبوصلة.\n'
          'زاوية القبلة المحسوبة لموقعك هي ${result.bearingDegrees}° (${QiblaCalculationService.cardinalDirectionAr(result.bearing)} من الشمال الحقيقي).',
    );
  }

  Widget _buildStatusFallbackCard(
    BuildContext context, {
    required Key cardKey,
    required IconData icon,
    required String title,
    required String body,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: cardKey,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      decoration: _cardDecoration(isDark),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 68,
            height: 68,
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
              icon,
              size: 30,
              color: isDark ? const Color(0xFFC9A15B) : const Color(0xFFC5A059),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Fustat',
              fontSize: 17.5,
              fontWeight: FontWeight.bold,
              color: isDark ? const Color(0xFFF6F1E7) : AppColors.primaryLight,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Fustat',
              fontSize: 13.5,
              height: 1.65,
              color: isDark ? const Color(0xFFD8CEBE) : const Color(0xFF707973),
            ),
          ),
        ],
      ),
    );
  }

  BoxDecoration _cardDecoration(bool isDark) {
    return BoxDecoration(
      color: isDark ? const Color(0xFF262D24) : const Color(0xFFFFFDF9),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(
        color: isDark ? const Color(0xFF353E32) : const Color(0xFFEADFCF),
        width: 1.2,
      ),
      boxShadow: [
        BoxShadow(
          color: isDark ? const Color(0x20000000) : const Color(0x0A000000),
          blurRadius: 14,
          offset: const Offset(0, 5),
        ),
      ],
    );
  }
}

/// Custom painter rendering the compass dial ring, degree ticks, cardinal
/// letters, and Qibla azimuth tick on the dial circumference.
class _CompassDialPainter extends CustomPainter {
  final bool isDark;
  final Color ringColor;
  final Color tickColor;
  final Color northColor;
  final double qiblaMarkerAngleDegrees;
  final Color qiblaMarkerColor;

  const _CompassDialPainter({
    required this.isDark,
    required this.ringColor,
    required this.tickColor,
    required this.northColor,
    required this.qiblaMarkerAngleDegrees,
    required this.qiblaMarkerColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = size.width / 2 - 4;

    final Paint ringPaint = Paint()
      ..color = ringColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, radius, ringPaint);

    final Paint innerRingPaint = Paint()
      ..color = ringColor.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, radius - 26, innerRingPaint);

    for (int deg = 0; deg < 360; deg += 15) {
      final bool isMajor = deg % 90 == 0;
      final bool isMedium = deg % 45 == 0;
      final double tickLen = isMajor ? 11.0 : (isMedium ? 7.0 : 4.0);
      final double rad = (deg - 90.0) * math.pi / 180.0;

      final Offset pOuter = Offset(
        center.dx + radius * math.cos(rad),
        center.dy + radius * math.sin(rad),
      );
      final Offset pInner = Offset(
        center.dx + (radius - tickLen) * math.cos(rad),
        center.dy + (radius - tickLen) * math.sin(rad),
      );

      final Paint tickPaint = Paint()
        ..color = deg == 0
            ? northColor
            : tickColor.withValues(alpha: isMajor ? 0.85 : 0.4)
        ..strokeWidth = isMajor ? 2.2 : 1.1;
      canvas.drawLine(pOuter, pInner, tickPaint);
    }

    // Qibla marker dot on the dial ring
    final double qiblaRad = (qiblaMarkerAngleDegrees - 90.0) * math.pi / 180.0;
    final Offset qiblaDot = Offset(
      center.dx + (radius - 13) * math.cos(qiblaRad),
      center.dy + (radius - 13) * math.sin(qiblaRad),
    );
    final Paint dotPaint = Paint()..color = qiblaMarkerColor;
    canvas.drawCircle(qiblaDot, 5.5, dotPaint);

    // Cardinal labels (N, E, S, W in Arabic initials)
    const cardinals = <int, String>{0: 'ش', 90: 'ق', 180: 'ج', 270: 'غ'};
    cardinals.forEach((deg, label) {
      final double rad = (deg - 90.0) * math.pi / 180.0;
      final Offset labelPos = Offset(
        center.dx + (radius - 38) * math.cos(rad),
        center.dy + (radius - 38) * math.sin(rad),
      );
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            fontFamily: 'Fustat',
            fontSize: deg == 0 ? 15 : 13,
            fontWeight: FontWeight.bold,
            color: deg == 0 ? northColor : tickColor,
          ),
        ),
        textDirection: TextDirection.rtl,
      )..layout();
      textPainter.paint(
        canvas,
        labelPos - Offset(textPainter.width / 2, textPainter.height / 2),
      );
    });
  }

  @override
  bool shouldRepaint(covariant _CompassDialPainter oldDelegate) {
    return oldDelegate.isDark != isDark ||
        oldDelegate.qiblaMarkerAngleDegrees != qiblaMarkerAngleDegrees ||
        oldDelegate.qiblaMarkerColor != qiblaMarkerColor;
  }
}
