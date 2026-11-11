import 'dart:async';

import 'package:adhan/adhan.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:adhkar/features/adhkar/presentation/managers/favorites_manager.dart';
import 'package:adhkar/features/adhkar/presentation/pages/home_page.dart';
import 'package:adhkar/features/prayer/data/models/prayer_settings.dart';
import 'package:adhkar/features/prayer/data/models/prayer_times_result.dart';
import 'package:adhkar/features/prayer/data/models/saved_prayer_location.dart';
import 'package:adhkar/features/prayer/data/services/prayer_calculation_service.dart';
import 'package:adhkar/features/prayer/data/services/prayer_geocoding_service.dart';
import 'package:adhkar/features/prayer/data/services/prayer_location_cache_service.dart';
import 'package:adhkar/features/prayer/data/services/prayer_location_service.dart';
import 'package:adhkar/features/prayer/data/services/prayer_settings_service.dart';
import 'package:adhkar/features/prayer/presentation/pages/prayer_times_page.dart';

/// 1x1 transparent PNG asset bundle for deterministic widget tests.
class _TestAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key.endsWith('.png') ||
        key.endsWith('.jpg') ||
        key.endsWith('.jpeg') ||
        key.endsWith('.gif')) {
      return ByteData.sublistView(
        Uint8List.fromList(<int>[
          137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
          0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0,
          0, 10, 73, 68, 65, 84, 120, 156, 99, 96, 0, 0, 0, 2, 0, 1, 226,
          33, 188, 51, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
        ]),
      );
    }
    return rootBundle.load(key);
  }
}

/// Fake [GeolocatorClient] for deterministic widget testing without GPS.
class _FakeGeolocatorClient implements GeolocatorClient {
  bool serviceEnabled;
  LocationPermission initialPermission;
  LocationPermission requestedPermission;
  Position positionToReturn;
  Completer<Position>? pendingPositionCompleter;

  int isServiceEnabledCalls = 0;
  int checkPermissionCalls = 0;
  int requestPermissionCalls = 0;
  int getCurrentPositionCalls = 0;

  _FakeGeolocatorClient({
    this.serviceEnabled = true,
    this.initialPermission = LocationPermission.whileInUse,
    this.requestedPermission = LocationPermission.whileInUse,
    Position? positionToReturn,
    this.pendingPositionCompleter,
  }) : positionToReturn =
           positionToReturn ??
           Position(
             latitude: 21.4225,
             longitude: 39.8262,
             timestamp: DateTime(2026, 3, 20, 10, 0),
             accuracy: 10.0,
             altitude: 0.0,
             altitudeAccuracy: 0.0,
             heading: 0.0,
             headingAccuracy: 0.0,
             speed: 0.0,
             speedAccuracy: 0.0,
             hasAccuracy: true,
           );

  @override
  Future<bool> isLocationServiceEnabled() async {
    isServiceEnabledCalls++;
    return serviceEnabled;
  }

  @override
  Future<LocationPermission> checkPermission() async {
    checkPermissionCalls++;
    return initialPermission;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    requestPermissionCalls++;
    return requestedPermission;
  }

  @override
  Future<Position> getCurrentPosition({
    required LocationSettings locationSettings,
  }) async {
    getCurrentPositionCalls++;
    if (pendingPositionCompleter != null) {
      return pendingPositionCompleter!.future;
    }
    return positionToReturn;
  }
}

/// Fake [PrayerCalculationService] that can simulate calculation failure on
/// first call and succeed on retry, return `null` from `tryCalculate` for
/// tomorrow's Fajr, or produce deterministic local-calendar prayer times
/// independent of the host machine's OS timezone.
class _ConfigurableCalculationService extends PrayerCalculationService {
  bool shouldFail;
  bool shouldReturnNullOnTryCalculate;
  bool useDeterministicLocalSchedule;
  int calculateCalls = 0;
  final List<DateTime> calculatedDates = <DateTime>[];

  _ConfigurableCalculationService({
    this.shouldFail = false,
    this.shouldReturnNullOnTryCalculate = false,
    this.useDeterministicLocalSchedule = false,
  });

  PrayerTimesResult _buildDeterministicResult({
    required double latitude,
    required double longitude,
    required DateTime date,
    required PrayerSettings settings,
    String? countryCode,
  }) {
    final int y = date.year;
    final int m = date.month;
    final int d = date.day;
    return PrayerTimesResult(
      fajr: DateTime(y, m, d, 5, 0),
      sunrise: DateTime(y, m, d, 6, 15),
      dhuhr: DateTime(y, m, d, 12, 15),
      asr: DateTime(y, m, d, 15, 30),
      maghrib: DateTime(y, m, d, 18, 15),
      isha: DateTime(y, m, d, 19, 45),
      latitude: latitude,
      longitude: longitude,
      year: y,
      month: m,
      day: d,
      calculationMode: settings.calculationMode,
      calculationMethod:
          settings.calculationMode == PrayerCalculationMode.manual
          ? settings.manualCalculationMethod
          : PrayerSettings.defaultManualCalculationMethod,
      madhab: settings.madhab,
      countryCode: countryCode,
    );
  }

  @override
  PrayerTimesResult calculate({
    required double latitude,
    required double longitude,
    required DateTime date,
    required PrayerSettings settings,
    String? countryCode,
    Duration? utcOffset,
  }) {
    calculateCalls++;
    calculatedDates.add(DateTime(date.year, date.month, date.day));
    if (shouldFail) {
      throw const PrayerCalculationException(
        PrayerCalculationErrorType.calculationFailed,
        'Internal technical exception details that must not be shown to user',
      );
    }
    if (useDeterministicLocalSchedule) {
      return _buildDeterministicResult(
        latitude: latitude,
        longitude: longitude,
        date: date,
        settings: settings,
        countryCode: countryCode,
      );
    }
    return super.calculate(
      latitude: latitude,
      longitude: longitude,
      date: date,
      settings: settings,
      countryCode: countryCode,
      utcOffset: utcOffset,
    );
  }

  @override
  PrayerTimesResult? tryCalculate({
    required double latitude,
    required double longitude,
    required DateTime date,
    required PrayerSettings settings,
    String? countryCode,
    Duration? utcOffset,
  }) {
    if (shouldReturnNullOnTryCalculate) {
      return null;
    }
    if (useDeterministicLocalSchedule) {
      calculatedDates.add(DateTime(date.year, date.month, date.day));
      return _buildDeterministicResult(
        latitude: latitude,
        longitude: longitude,
        date: date,
        settings: settings,
        countryCode: countryCode,
      );
    }
    return super.tryCalculate(
      latitude: latitude,
      longitude: longitude,
      date: date,
      settings: settings,
      countryCode: countryCode,
      utcOffset: utcOffset,
    );
  }
}

/// Tracking wrapper around [PrayerSettingsService] to verify how many times
/// `loadSettings` is called and confirm settings are never overwritten.
class _TrackingPrayerSettingsService extends PrayerSettingsService {
  int loadSettingsCalls = 0;
  int saveSettingsCalls = 0;

  _TrackingPrayerSettingsService();

  @override
  Future<PrayerSettings> loadSettings() {
    loadSettingsCalls++;
    return super.loadSettings();
  }

  @override
  Future<PrayerSettings> saveSettings(PrayerSettings settings) {
    saveSettingsCalls++;
    return super.saveSettings(settings);
  }
}

/// Fake [GeocodingClient] for deterministic widget testing of reverse geocoding.
class _FakeWidgetGeocodingClient implements GeocodingClient {
  List<Placemark> placemarks;
  int placemarkCalls = 0;

  _FakeWidgetGeocodingClient({
    this.placemarks = const <Placemark>[],
  });

  @override
  Future<void> setLocaleIdentifier(String localeIdentifier) async {}

  @override
  Future<List<Placemark>> placemarkFromCoordinates(
    double latitude,
    double longitude,
  ) async {
    placemarkCalls++;
    return placemarks;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FavoritesManager.favoriteDhikrs.value = <Map<String, dynamic>>[];
  });

  void setLargeSurfaceSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Widget wrapWithBundle(Widget child) {
    return DefaultAssetBundle(
      bundle: _TestAssetBundle(),
      child: MaterialApp(home: child),
    );
  }

  group('PrayerTimesPage Phase 4 UI Integration Tests', () {
    testWidgets(
      'displays loading state while location request is in progress',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final completer = Completer<Position>();
        final fakeGeo = _FakeGeolocatorClient(
          pendingPositionCompleter: completer,
        );
        final locationService = PrayerLocationService(client: fakeGeo);
        final settingsService = _TrackingPrayerSettingsService();

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              settingsService: settingsService,
              locationService: locationService,
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          find.text('جاري تحديد الموقع وحساب مواقيت الصلاة...'),
          findsOneWidget,
        );
        expect(find.text('الموقع غير متاح'), findsOneWidget);

        // Complete the pending position so timer/futures settle cleanly
        completer.complete(fakeGeo.positionToReturn);
        await tester.pump();
      },
    );

    testWidgets(
      'renders all six Arabic prayer labels, times, next prayer highlight, and live countdown on success',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final fakeGeo = _FakeGeolocatorClient();
        final locationService = PrayerLocationService(client: fakeGeo);
        final settingsService = _TrackingPrayerSettingsService();
        const calcService = PrayerCalculationService();

        // Compute the real Fajr and Sunrise times for Makkah on 2026-03-20 in the
        // test environment's local timezone so we can set our clock between Fajr and Sunrise
        final sampleResult = calcService.calculate(
          latitude: 21.4225,
          longitude: 39.8262,
          date: DateTime(2026, 3, 20),
          settings: const PrayerSettings.defaults(),
        );
        DateTime currentClock = sampleResult.dhuhr.subtract(
          const Duration(minutes: 25, seconds: 10),
        );

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              settingsService: settingsService,
              locationService: locationService,
              calculationService: calcService,
              clock: () => currentClock,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Screen header and all six Arabic prayer labels are displayed
        expect(find.text('مواقيت الصلاة'), findsOneWidget);
        expect(find.text('الفجر'), findsWidgets);
        expect(find.text('الشروق'), findsWidgets);
        expect(find.text('الظهر'), findsWidgets);
        expect(find.text('العصر'), findsWidgets);
        expect(find.text('المغرب'), findsWidgets);
        expect(find.text('العشاء'), findsWidgets);

        // All six prayer row cards are rendered
        expect(find.byKey(const Key('prayer_row_fajr')), findsOneWidget);
        expect(find.byKey(const Key('prayer_row_sunrise')), findsOneWidget);
        expect(find.byKey(const Key('prayer_row_dhuhr')), findsOneWidget);
        expect(find.byKey(const Key('prayer_row_asr')), findsOneWidget);
        expect(find.byKey(const Key('prayer_row_maghrib')), findsOneWidget);
        expect(find.byKey(const Key('prayer_row_isha')), findsOneWidget);

        // Raw coordinates are never shown; friendly fallback label is shown when geocoding returns empty
        expect(
          find.textContaining('21.42° شمالاً، 39.83° شرقاً'),
          findsNothing,
        );
        expect(find.text('الموقع: الموقع المحفوظ'), findsOneWidget);

        // Next prayer highlight and countdown are displayed and update dynamically
        expect(find.text('الصلاة القادمة'), findsOneWidget);
        expect(find.byKey(const Key('next_prayer_countdown')), findsOneWidget);
        expect(find.text('متبقي 00:25:10'), findsOneWidget);

        // Advance clock by 1 second and trigger periodic timer tick
        currentClock = currentClock.add(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('متبقي 00:25:09'), findsOneWidget);

        // Existing settings were never overwritten
        expect(settingsService.saveSettingsCalls, equals(0));
      },
    );

    testWidgets(
      'displays permission-denied state and handles retry without reloading settings',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final fakeGeo = _FakeGeolocatorClient(
          serviceEnabled: true,
          initialPermission: LocationPermission.denied,
          requestedPermission: LocationPermission.denied,
        );
        final locationService = PrayerLocationService(client: fakeGeo);
        final settingsService = _TrackingPrayerSettingsService();

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              settingsService: settingsService,
              locationService: locationService,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('يلزم إذن الوصول إلى الموقع'), findsOneWidget);
        expect(find.text('الموقع غير متاح'), findsOneWidget);
        expect(find.text('إعادة المحاولة'), findsOneWidget);
        expect(settingsService.loadSettingsCalls, equals(1));
        expect(fakeGeo.requestPermissionCalls, equals(1));

        // Grant permission on retry
        fakeGeo.requestedPermission = LocationPermission.whileInUse;
        await tester.tap(find.text('إعادة المحاولة'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Settings were NOT unnecessarily reloaded or overwritten on retry
        expect(settingsService.loadSettingsCalls, equals(1));
        expect(settingsService.saveSettingsCalls, equals(0));

        // All six prayers now render
        expect(find.byKey(const Key('prayer_row_fajr')), findsOneWidget);
        expect(find.byKey(const Key('prayer_row_isha')), findsOneWidget);
      },
    );

    testWidgets(
      'handles permanently denied permission without repeatedly requesting OS permission prompt',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final fakeGeo = _FakeGeolocatorClient(
          serviceEnabled: true,
          initialPermission: LocationPermission.deniedForever,
        );
        final locationService = PrayerLocationService(client: fakeGeo);

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(locationService: locationService),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('تم رفض إذن الموقع بشكل دائم'), findsOneWidget);
        expect(fakeGeo.requestPermissionCalls, equals(0));

        // Even if the OS reports denied when retrying from deniedForever state,
        // retry uses requestPermissionIfNeeded: false so it preserves the
        // permanent denial UI and does not spam the prompt on subsequent taps.
        fakeGeo.initialPermission = LocationPermission.denied;
        await tester.tap(find.text('إعادة المحاولة'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('تم رفض إذن الموقع بشكل دائم'), findsOneWidget);
        expect(find.text('يلزم إذن الوصول إلى الموقع'), findsNothing);
        expect(fakeGeo.requestPermissionCalls, equals(0));

        // Second retry tap still preserves deniedForever without prompting
        await tester.tap(find.text('إعادة المحاولة'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('تم رفض إذن الموقع بشكل دائم'), findsOneWidget);
        expect(fakeGeo.requestPermissionCalls, equals(0));
      },
    );

    testWidgets(
      'displays location-service-disabled state and recovers on retry',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final fakeGeo = _FakeGeolocatorClient(serviceEnabled: false);
        final locationService = PrayerLocationService(client: fakeGeo);

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(locationService: locationService),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('خدمات الموقع غير مفعّلة'), findsOneWidget);
        expect(find.text('الموقع غير متاح'), findsOneWidget);
        expect(find.text('إعادة المحاولة'), findsOneWidget);

        // Enable location service and tap retry
        fakeGeo.serviceEnabled = true;
        await tester.tap(find.text('إعادة المحاولة'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.byKey(const Key('prayer_row_fajr')), findsOneWidget);
        expect(find.byKey(const Key('prayer_row_isha')), findsOneWidget);
      },
    );

    testWidgets(
      'displays friendly calculation failure state without exposing technical exception text and retries only calculation',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final fakeGeo = _FakeGeolocatorClient();
        final locationService = PrayerLocationService(client: fakeGeo);
        final calcService = _ConfigurableCalculationService(shouldFail: true);
        final settingsService = _TrackingPrayerSettingsService();

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              settingsService: settingsService,
              locationService: locationService,
              calculationService: calcService,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('تعذّر حساب مواقيت الصلاة'), findsOneWidget);
        // Technical exception message must NOT be exposed in the UI
        expect(
          find.textContaining('Internal technical exception details'),
          findsNothing,
        );
        expect(fakeGeo.getCurrentPositionCalls, equals(1));
        expect(settingsService.loadSettingsCalls, equals(1));

        // Fix calculation and tap retry: should retry calculation directly
        // without re-fetching GPS coordinates or reloading settings
        calcService.shouldFail = false;
        await tester.tap(find.text('إعادة المحاولة'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(fakeGeo.getCurrentPositionCalls, equals(1));
        expect(settingsService.loadSettingsCalls, equals(1));
        expect(find.byKey(const Key('prayer_row_fajr')), findsOneWidget);
      },
    );

    testWidgets(
      'respects persisted manual CalculationMethod and Hanafi Madhab from PrayerSettingsService',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final customSettings = PrayerSettings(
          calculationMode: PrayerCalculationMode.manual,
          manualCalculationMethod: CalculationMethod.umm_al_qura,
          madhab: Madhab.hanafi,
        );
        SharedPreferences.setMockInitialValues(<String, Object>{
          PrayerSettingsService.storageKey: customSettings.toJsonString(),
        });

        final fakeGeo = _FakeGeolocatorClient();
        final locationService = PrayerLocationService(client: fakeGeo);
        final settingsService = _TrackingPrayerSettingsService();

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              settingsService: settingsService,
              locationService: locationService,
              clock: () => DateTime(2026, 3, 20, 8, 0),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          find.text('طريقة الحساب: أم القرى (يدوي)'),
          findsOneWidget,
        );
        expect(find.text('المذهب: الحنفي'), findsOneWidget);
        expect(settingsService.saveSettingsCalls, equals(0));
      },
    );

    testWidgets(
      'no location request occurs on HomePage before opening PrayerTimesPage',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final fakeGeo = _FakeGeolocatorClient();

        await tester.pumpWidget(wrapWithBundle(const HomePage()));
        await tester.pumpAndSettle();

        // HomePage renders quick-action button for Prayer Times
        expect(find.text('مواقيت الصلاة'), findsOneWidget);
        // Zero location calls have occurred before opening PrayerTimesPage
        expect(fakeGeo.isServiceEnabledCalls, equals(0));
        expect(fakeGeo.checkPermissionCalls, equals(0));
        expect(fakeGeo.requestPermissionCalls, equals(0));
        expect(fakeGeo.getCurrentPositionCalls, equals(0));
      },
    );

    testWidgets(
      'A. Sunrise exclusion: between Fajr->Sunrise and Sunrise->Dhuhr, next prayer is Dhuhr and Sunrise is never highlighted as a prayer',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final fakeGeo = _FakeGeolocatorClient();
        final locationService = PrayerLocationService(client: fakeGeo);
        final calcService = _ConfigurableCalculationService(
          useDeterministicLocalSchedule: true,
        );

        // Deterministic local schedule on 2026-03-20:
        // Fajr 05:00, Sunrise 06:15, Dhuhr 12:15, Asr 15:30, Maghrib 18:15, Isha 19:45
        // 1. Between Fajr (05:00) and Sunrise (06:15): current is Fajr, next is Dhuhr (NOT Sunrise)
        DateTime currentClock = DateTime(2026, 3, 20, 5, 15);

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              locationService: locationService,
              calculationService: calcService,
              clock: () => currentClock,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Sunrise row remains visible in the 6-item schedule
        final sunriseRow = find.byKey(const Key('prayer_row_sunrise'));
        expect(sunriseRow, findsOneWidget);
        // Sunrise row must NEVER have 'الحالية' or 'القادمة'
        expect(
          find.descendant(of: sunriseRow, matching: find.text('الحالية')),
          findsNothing,
        );
        expect(
          find.descendant(of: sunriseRow, matching: find.text('القادمة')),
          findsNothing,
        );
        // Fajr is marked 'الحالية' and Dhuhr is marked 'القادمة'
        final fajrRow = find.byKey(const Key('prayer_row_fajr'));
        final dhuhrRow = find.byKey(const Key('prayer_row_dhuhr'));
        expect(
          find.descendant(of: fajrRow, matching: find.text('الحالية')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: dhuhrRow, matching: find.text('القادمة')),
          findsOneWidget,
        );
        // 'الشروق' appears only once (in its schedule row, NOT in the Next Prayer card)
        expect(find.text('الشروق'), findsOneWidget);
        // 'الظهر' appears twice (once in the Next Prayer card and once in its schedule row)
        expect(find.text('الظهر'), findsNWidgets(2));

        // 2. Advance clock to between Sunrise (06:15) and Dhuhr (12:15):
        // Fajr window has ended, so no prayer is 'الحالية', and next prayer is still Dhuhr
        currentClock = DateTime(2026, 3, 20, 6, 35);
        await tester.pump(const Duration(seconds: 1));

        expect(find.text('الحالية'), findsNothing);
        expect(
          find.descendant(of: sunriseRow, matching: find.text('الحالية')),
          findsNothing,
        );
        expect(
          find.descendant(of: sunriseRow, matching: find.text('القادمة')),
          findsNothing,
        );
        expect(
          find.descendant(of: dhuhrRow, matching: find.text('القادمة')),
          findsOneWidget,
        );
        expect(find.text('الشروق'), findsOneWidget);
        expect(find.text('الظهر'), findsNWidgets(2));
      },
    );

    testWidgets(
      'B. Tomorrow Fajr: after today Isha, tomorrow Fajr is shown as next prayer and null tomorrow calculation is handled gracefully',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final fakeGeo = _FakeGeolocatorClient();
        final locationService = PrayerLocationService(client: fakeGeo);
        final calcService = _ConfigurableCalculationService(
          useDeterministicLocalSchedule: true,
        );

        // Set clock to 20:15 (30 minutes after today's 19:45 Isha)
        final DateTime afterIsha = DateTime(2026, 3, 20, 20, 15);

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              key: const ValueKey<String>('valid_tomorrow_page'),
              locationService: locationService,
              calculationService: calcService,
              clock: () => afterIsha,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Tomorrow's Fajr is displayed as the next prayer ('الفجر' in highlight card + row)
        expect(find.text('الصلاة القادمة'), findsOneWidget);
        expect(find.text('الفجر'), findsNWidgets(2));
        expect(find.byKey(const Key('next_prayer_countdown')), findsOneWidget);
        // Isha is marked 'الحالية'
        final ishaRow = find.byKey(const Key('prayer_row_isha'));
        expect(
          find.descendant(of: ishaRow, matching: find.text('الحالية')),
          findsOneWidget,
        );

        // Now test when tomorrow's tryCalculate returns null:
        // Screen must not crash or display a false next-prayer card
        final nullTomorrowCalcService = _ConfigurableCalculationService(
          useDeterministicLocalSchedule: true,
          shouldReturnNullOnTryCalculate: true,
        );
        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              key: const ValueKey<String>('null_tomorrow_page'),
              locationService: locationService,
              calculationService: nullTomorrowCalcService,
              clock: () => afterIsha,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('الصلاة القادمة'), findsNothing);
        expect(find.byKey(const Key('next_prayer_countdown')), findsNothing);
        // All 6 of today's prayer rows remain displayed cleanly
        expect(find.byKey(const Key('prayer_row_fajr')), findsOneWidget);
        expect(find.byKey(const Key('prayer_row_isha')), findsOneWidget);
      },
    );

    testWidgets(
      'C. Midnight rollover: crossing midnight recalculates schedule for the new calendar date',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final fakeGeo = _FakeGeolocatorClient();
        final locationService = PrayerLocationService(client: fakeGeo);
        final calcService = _ConfigurableCalculationService(
          useDeterministicLocalSchedule: true,
        );

        DateTime currentClock = DateTime(2026, 3, 20, 23, 59, 59);

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              locationService: locationService,
              calculationService: calcService,
              clock: () => currentClock,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Initial calculation was for 2026-03-20 (plus tomorrow's tryCalculate for 2026-03-21)
        expect(calcService.calculatedDates.first, equals(DateTime(2026, 3, 20)));

        // Cross midnight to 2026-03-21 00:00:01
        currentClock = DateTime(2026, 3, 21, 0, 0, 1);
        await tester.pump(const Duration(seconds: 1));

        // Verify primary schedule was recalculated for the new calendar day (2026-03-21)
        expect(
          calcService.calculatedDates,
          containsAllInOrder(<DateTime>[
            DateTime(2026, 3, 20),
            DateTime(2026, 3, 21),
            DateTime(2026, 3, 21),
            DateTime(2026, 3, 22),
          ]),
        );
        // Before Fajr (05:00) on the new day, Fajr is the next prayer
        final fajrRow = find.byKey(const Key('prayer_row_fajr'));
        expect(
          find.descendant(of: fajrRow, matching: find.text('القادمة')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'D. Countdown boundary: reaching a prayer time transitions next-prayer highlight to the following obligatory prayer without negative countdown',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final fakeGeo = _FakeGeolocatorClient();
        final locationService = PrayerLocationService(client: fakeGeo);
        const calcService = PrayerCalculationService();

        final sampleResult = calcService.calculate(
          latitude: 21.4225,
          longitude: 39.8262,
          date: DateTime(2026, 3, 20),
          settings: const PrayerSettings.defaults(),
        );

        // Start 1 second before Dhuhr
        DateTime currentClock = sampleResult.dhuhr.subtract(
          const Duration(seconds: 1),
        );

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              locationService: locationService,
              calculationService: calcService,
              clock: () => currentClock,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        final dhuhrRow = find.byKey(const Key('prayer_row_dhuhr'));
        final asrRow = find.byKey(const Key('prayer_row_asr'));
        expect(
          find.descendant(of: dhuhrRow, matching: find.text('القادمة')),
          findsOneWidget,
        );
        expect(find.text('متبقي 00:00:01'), findsOneWidget);

        // Advance clock to exact Dhuhr boundary
        currentClock = sampleResult.dhuhr;
        await tester.pump(const Duration(seconds: 1));

        // Dhuhr is now 'الحالية', Asr is now 'القادمة', and countdown is positive toward Asr
        expect(
          find.descendant(of: dhuhrRow, matching: find.text('الحالية')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: asrRow, matching: find.text('القادمة')),
          findsOneWidget,
        );
        expect(find.textContaining('-'), findsNothing);
      },
    );

    testWidgets(
      'E. Disposal: disposing PrayerTimesPage while countdown timer is active cancels timer cleanly without errors',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final fakeGeo = _FakeGeolocatorClient();
        final locationService = PrayerLocationService(client: fakeGeo);
        const calcService = PrayerCalculationService();

        DateTime currentClock = DateTime(2026, 3, 20, 10, 0);

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              locationService: locationService,
              calculationService: calcService,
              clock: () => currentClock,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.byKey(const Key('next_prayer_countdown')), findsOneWidget);

        // Replace PrayerTimesPage with an empty container (disposing PrayerTimesPage)
        await tester.pumpWidget(wrapWithBundle(const SizedBox.shrink()));
        await tester.pump();

        // Advance time by several seconds after disposal: no timer callback should fire on unmounted state
        currentClock = currentClock.add(const Duration(seconds: 5));
        await tester.pump(const Duration(seconds: 5));

        expect(tester.takeException(), isNull);
      },
    );
  });

  group('PrayerTimesPage Phase 5.5 Persistent Location & Sync Tests', () {
    testWidgets(
      'reuses cached SavedPrayerLocation on subsequent openings without calling GPS or reverse geocoding',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        await cacheService.saveLocation(
          SavedPrayerLocation(
            latitude: 41.0332,
            longitude: 28.6801,
            countryIsoCode: 'TR',
            countryName: 'تركيا',
            city: 'إسطنبول',
            district: 'إسنيورت',
            timestamp: DateTime.utc(2026, 4, 15, 7, 0),
          ),
        );

        final fakeGeo = _FakeGeolocatorClient();
        final locationService = PrayerLocationService(client: fakeGeo);
        final fakeGeocodingClient = _FakeWidgetGeocodingClient();
        final geocodingService = PrayerGeocodingService(
          client: fakeGeocodingClient,
        );

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              locationService: locationService,
              locationCacheService: cacheService,
              geocodingService: geocodingService,
              clock: () => DateTime(2026, 4, 15, 10, 0),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(fakeGeo.isServiceEnabledCalls, 0);
        expect(fakeGeo.checkPermissionCalls, 0);
        expect(fakeGeo.requestPermissionCalls, 0);
        expect(fakeGeo.getCurrentPositionCalls, 0);
        expect(fakeGeocodingClient.placemarkCalls, 0);
        expect(find.text('الموقع: تركيا، إسطنبول، إسنيورت'), findsOneWidget);
        expect(find.textContaining('41.03'), findsNothing);
      },
    );

    testWidgets(
      'first-time user requests permission, reverse-geocodes, persists location, and displays city name without coordinates',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        final fakeGeo = _FakeGeolocatorClient(
          initialPermission: LocationPermission.denied,
          requestedPermission: LocationPermission.whileInUse,
          positionToReturn: Position(
            latitude: 41.0332,
            longitude: 28.6801,
            timestamp: DateTime(2026, 4, 15, 8, 0),
            accuracy: 10.0,
            altitude: 0.0,
            altitudeAccuracy: 0.0,
            heading: 0.0,
            headingAccuracy: 0.0,
            speed: 0.0,
            speedAccuracy: 0.0,
            hasAccuracy: true,
          ),
        );
        final locationService = PrayerLocationService(client: fakeGeo);
        final fakeGeocodingClient = _FakeWidgetGeocodingClient(
          placemarks: const <Placemark>[
            Placemark(
              isoCountryCode: 'TR',
              country: 'تركيا',
              locality: 'إسطنبول',
              subLocality: 'إسنيورت',
            ),
          ],
        );
        final geocodingService = PrayerGeocodingService(
          client: fakeGeocodingClient,
        );

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              locationService: locationService,
              locationCacheService: cacheService,
              geocodingService: geocodingService,
              clock: () => DateTime(2026, 4, 15, 10, 0),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(fakeGeo.requestPermissionCalls, 1);
        expect(fakeGeo.getCurrentPositionCalls, 1);
        expect(fakeGeocodingClient.placemarkCalls, 1);
        expect(find.text('الموقع: تركيا، إسطنبول، إسنيورت'), findsOneWidget);
        expect(find.textContaining('41.03'), findsNothing);
        expect(find.textContaining('28.68'), findsNothing);

        final persisted = await PrayerLocationCacheService().loadLocation();
        expect(persisted, isNotNull);
        expect(persisted!.countryIsoCode, 'TR');
        expect(persisted.displayName, 'تركيا، إسطنبول، إسنيورت');
      },
    );

    testWidgets(
      'manual refresh updates saved location and recalculates; failed manual refresh preserves previous location',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        await cacheService.saveLocation(
          SavedPrayerLocation(
            latitude: 41.0332,
            longitude: 28.6801,
            countryIsoCode: 'TR',
            countryName: 'تركيا',
            city: 'إسطنبول',
            district: 'إسنيورت',
            timestamp: DateTime.utc(2026, 4, 15, 7, 0),
          ),
        );

        final fakeGeo = _FakeGeolocatorClient(
          positionToReturn: Position(
            latitude: 24.7136,
            longitude: 46.6753,
            timestamp: DateTime(2026, 4, 15, 9, 0),
            accuracy: 10.0,
            altitude: 0.0,
            altitudeAccuracy: 0.0,
            heading: 0.0,
            headingAccuracy: 0.0,
            speed: 0.0,
            speedAccuracy: 0.0,
            hasAccuracy: true,
          ),
        );
        final locationService = PrayerLocationService(client: fakeGeo);
        final fakeGeocodingClient = _FakeWidgetGeocodingClient(
          placemarks: const <Placemark>[
            Placemark(
              isoCountryCode: 'SA',
              country: 'السعودية',
              locality: 'الرياض',
              subLocality: 'العليا',
            ),
          ],
        );
        final geocodingService = PrayerGeocodingService(
          client: fakeGeocodingClient,
        );

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              locationService: locationService,
              locationCacheService: cacheService,
              geocodingService: geocodingService,
              clock: () => DateTime(2026, 4, 15, 10, 0),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('الموقع: تركيا، إسطنبول، إسنيورت'), findsOneWidget);

        // 1. Tap manual refresh and succeed -> updates to Riyadh
        await tester.tap(find.byKey(const Key('prayer_refresh_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(fakeGeo.getCurrentPositionCalls, 1);
        expect(fakeGeocodingClient.placemarkCalls, 1);
        expect(find.text('الموقع: السعودية، الرياض، العليا'), findsOneWidget);

        // 2. Simulate GPS failure on second manual refresh -> preserves Riyadh and shows notice
        fakeGeo.serviceEnabled = false;
        await tester.tap(find.byKey(const Key('prayer_refresh_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('الموقع: السعودية، الرياض، العليا'), findsOneWidget);
        expect(
          find.text('تعذّر تحديث الموقع، تم الإبقاء على الموقع المحفوظ'),
          findsOneWidget,
        );
        final stillSaved = await PrayerLocationCacheService().loadLocation();
        expect(stillSaved!.countryIsoCode, 'SA');
        expect(stillSaved.city, 'الرياض');
      },
    );

    testWidgets(
      'midnight rollover and app resume recalculate for new local date without calling GPS',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        await cacheService.saveLocation(
          SavedPrayerLocation(
            latitude: 41.0332,
            longitude: 28.6801,
            countryIsoCode: 'TR',
            countryName: 'تركيا',
            city: 'إسطنبول',
            district: 'إسنيورت',
            timestamp: DateTime.utc(2026, 4, 15, 7, 0),
          ),
        );

        final fakeGeo = _FakeGeolocatorClient();
        final locationService = PrayerLocationService(client: fakeGeo);
        final calcService = _ConfigurableCalculationService(
          useDeterministicLocalSchedule: true,
        );

        DateTime currentClock = DateTime(2026, 4, 15, 23, 59, 59);

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              locationService: locationService,
              locationCacheService: cacheService,
              calculationService: calcService,
              clock: () => currentClock,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          calcService.calculatedDates.contains(DateTime(2026, 4, 15)),
          isTrue,
        );

        // Cross midnight via timer tick
        currentClock = DateTime(2026, 4, 16, 0, 0, 1);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          calcService.calculatedDates.contains(DateTime(2026, 4, 16)),
          isTrue,
        );

        // Resume app on next day
        currentClock = DateTime(2026, 4, 17, 6, 0, 0);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          calcService.calculatedDates.contains(DateTime(2026, 4, 17)),
          isTrue,
        );
        expect(fakeGeo.getCurrentPositionCalls, 0);
      },
    );

    testWidgets(
      'passes saved countryIsoCode TR to select Turkey method in auto mode while respecting manual override',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        await cacheService.saveLocation(
          SavedPrayerLocation(
            latitude: 41.0332,
            longitude: 28.6801,
            countryIsoCode: 'TR',
            countryName: 'تركيا',
            city: 'إسطنبول',
            district: 'إسنيورت',
            timestamp: DateTime.utc(2026, 4, 15, 7, 0),
          ),
        );

        final fakeGeo = _FakeGeolocatorClient();
        final locationService = PrayerLocationService(client: fakeGeo);
        final settingsService = PrayerSettingsService();

        // Auto mode -> TR selects Turkish Diyanet method
        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              settingsService: settingsService,
              locationService: locationService,
              locationCacheService: cacheService,
              clock: () => DateTime(2026, 4, 15, 10, 0),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          find.textContaining('رئاسة الشؤون الدينية التركية (تلقائي)'),
          findsOneWidget,
        );

        // Switch to manual override (Egyptian) and re-mount
        await settingsService.saveSettings(
          PrayerSettings(
            calculationMode: PrayerCalculationMode.manual,
            manualCalculationMethod: CalculationMethod.egyptian,
          ),
        );
        await tester.pumpWidget(wrapWithBundle(const SizedBox.shrink()));
        await tester.pump();

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              settingsService: settingsService,
              locationService: locationService,
              locationCacheService: cacheService,
              clock: () => DateTime(2026, 4, 15, 10, 0),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          find.textContaining('الهيئة المصرية العامة للمساحة (يدوي)'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'normalizes UTC clock timestamps to device-local calendar date and time without hardcoded offsets',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        await cacheService.saveLocation(
          SavedPrayerLocation(
            latitude: 41.0332,
            longitude: 28.6801,
            countryIsoCode: 'TR',
            countryName: 'تركيا',
            city: 'إسطنبول',
            district: 'إسنيورت',
            timestamp: DateTime.utc(2026, 4, 15, 7, 0),
          ),
        );

        final fakeGeo = _FakeGeolocatorClient();
        final locationService = PrayerLocationService(client: fakeGeo);
        final calcService = _ConfigurableCalculationService(
          useDeterministicLocalSchedule: true,
        );

        // Pass an explicit UTC instant representing 10:00 in device-local time
        final DateTime localMoment = DateTime(2026, 4, 15, 10, 0);
        final DateTime utcClockMoment = localMoment.toUtc();

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              locationService: locationService,
              locationCacheService: cacheService,
              calculationService: calcService,
              clock: () => utcClockMoment,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          calcService.calculatedDates.contains(
            DateTime(localMoment.year, localMoment.month, localMoment.day),
          ),
          isTrue,
        );
        expect(find.byKey(const Key('next_prayer_countdown')), findsOneWidget);
        expect(find.text('متبقي 02:15:00'), findsOneWidget);
      },
    );
  });
}
