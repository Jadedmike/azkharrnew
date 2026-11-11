import 'package:adhkar/features/adhkar/presentation/managers/settings_manager.dart';
import 'package:adhkar/features/prayer/data/models/prayer_notification_settings.dart';
import 'package:adhkar/features/prayer/data/models/prayer_settings.dart';
import 'package:adhkar/features/prayer/data/models/prayer_times_result.dart';
import 'package:adhkar/features/prayer/data/services/prayer_calculation_service.dart';
import 'package:adhkar/features/prayer/data/services/prayer_location_service.dart';
import 'package:adhkar/features/prayer/data/services/prayer_notification_service.dart';
import 'package:adhkar/features/prayer/data/services/prayer_notification_settings_service.dart';
import 'package:adhkar/features/prayer/data/services/prayer_settings_service.dart';
import 'package:adhkar/features/prayer/presentation/pages/prayer_settings_page.dart';
import 'package:adhkar/features/prayer/presentation/pages/prayer_times_page.dart';
import 'package:adhan/adhan.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class _TestAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key.endsWith('.png') ||
        key.endsWith('.jpg') ||
        key.endsWith('.jpeg') ||
        key.endsWith('.gif')) {
      return ByteData.sublistView(
        Uint8List.fromList([
          137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0,
          0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 108, 137, 0, 0, 0, 10, 73,
          68, 65, 84, 120, 156, 99, 96, 0, 0, 0, 2, 0, 1, 226, 33, 188, 51, 0,
          0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
        ]),
      );
    }
    return rootBundle.load(key);
  }
}

class _FakeLocationClient implements GeolocatorClient {
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<Position> getCurrentPosition({
    required LocationSettings locationSettings,
  }) async {
    return Position(
      longitude: 39.8262,
      latitude: 21.4225,
      timestamp: DateTime(2026, 3, 20, 8, 0),
      accuracy: 10.0,
      altitude: 0.0,
      altitudeAccuracy: 0.0,
      heading: 0.0,
      headingAccuracy: 0.0,
      speed: 0.0,
      speedAccuracy: 0.0,
    );
  }

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> requestPermission() async =>
      LocationPermission.whileInUse;
}

class _FailingCoordinateCachePrefs implements SharedPreferences {
  final Map<String, Object> _store = <String, Object>{};

  @override
  Object? get(String key) => _store[key];

  @override
  Future<bool> setString(String key, String value) async {
    if (key == PrayerNotificationSettingsService.coordinatesCacheKey) {
      return false;
    }
    _store[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _store.remove(key);
    return true;
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LocalDeterministicCalculationService extends PrayerCalculationService {
  const _LocalDeterministicCalculationService();

  @override
  PrayerTimesResult calculate({
    required double latitude,
    required double longitude,
    required DateTime date,
    required PrayerSettings settings,
    String? countryCode,
    Duration? utcOffset,
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
}

class _FakeUiNotificationClient implements PrayerNotificationClient {
  bool permissionGranted;
  bool nextRequestResult;
  int requestPermissionCalls = 0;
  int openAppSettingsCalls = 0;
  final Map<int, NotificationDetails> scheduledDetails =
      <int, NotificationDetails>{};
  final List<int> cancelledIds = <int>[];

  _FakeUiNotificationClient({
    this.permissionGranted = false,
    this.nextRequestResult = true,
  });

  @override
  Future<bool> isPermissionGranted() async => permissionGranted;

  @override
  Future<bool> requestPermission() async {
    requestPermissionCalls++;
    permissionGranted = nextRequestResult;
    return nextRequestResult;
  }

  @override
  Future<bool> canScheduleExactNotifications() async => true;

  @override
  Future<bool> openAppSettings() async {
    openAppSettingsCalls++;
    return true;
  }

  @override
  Future<String> getLocalTimezone() async => 'UTC';

  @override
  Future<void> createAndroidChannels(
    List<AndroidNotificationChannel> channels,
  ) async {}

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async {
    return scheduledDetails.keys
        .map((id) => PendingNotificationRequest(id, 'title', 'body', null))
        .toList();
  }

  @override
  Future<void> cancel(int id) async {
    cancelledIds.add(id);
    scheduledDetails.remove(id);
  }

  @override
  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
  }) async {
    scheduledDetails[id] = notificationDetails;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('UTC'));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsManager.init();
  });

  void setLargeSurface(WidgetTester tester) {
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

  group('PrayerSettingsPage UI Integration Tests', () {
    testWidgets(
      'calculation mode, manual method, and Madhab selection persist without touching Adhkar SettingsManager',
      (WidgetTester tester) async {
        setLargeSurface(tester);
        final prayerSettingsService = PrayerSettingsService();
        final notifSettingsService = PrayerNotificationSettingsService();
        final fakeClient = _FakeUiNotificationClient(permissionGranted: true);
        final notifService = PrayerNotificationService(
          client: fakeClient,
          prayerSettingsService: prayerSettingsService,
          notificationSettingsService: notifSettingsService,
        );

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerSettingsPage(
              settingsService: prayerSettingsService,
              notificationSettingsService: notifSettingsService,
              notificationService: notifService,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // No permission dialog on page open
        expect(fakeClient.requestPermissionCalls, equals(0));
        // Auto mode displays honest MWL fallback note
        expect(find.byKey(const Key('auto_mode_fallback_note')), findsOneWidget);

        // Switch to manual mode -> manual method dropdown appears
        await tester.tap(find.byKey(const Key('calc_mode_manual')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('manual_calculation_method_dropdown')),
          findsOneWidget,
        );
        expect(
          prayerSettingsService.currentSettings.calculationMode,
          equals(PrayerCalculationMode.manual),
        );

        // Select Umm al-Qura method
        await tester.tap(
          find.byKey(const Key('manual_calculation_method_dropdown')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('أم القرى').last);
        await tester.pumpAndSettle();
        expect(
          prayerSettingsService.currentSettings.manualCalculationMethod,
          equals(CalculationMethod.umm_al_qura),
        );

        // Switch Madhab to Hanafi
        await tester.tap(find.byKey(const Key('madhab_hanafi')));
        await tester.pumpAndSettle();
        expect(
          prayerSettingsService.currentSettings.madhab,
          equals(Madhab.hanafi),
        );

        // Adhkar SettingsManager keys remain unaffected
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('morning_reminder'), isFalse);
        expect(prefs.containsKey('evening_reminder'), isFalse);
      },
    );

    testWidgets(
      'enabling prayer notifications shows Arabic rationale before requesting OS permission, supports toggles & sound mode, and excludes Sunrise',
      (WidgetTester tester) async {
        setLargeSurface(tester);
        final prayerSettingsService = PrayerSettingsService();
        final notifSettingsService = PrayerNotificationSettingsService();
        final fakeClient = _FakeUiNotificationClient(
          permissionGranted: false,
          nextRequestResult: true,
        );
        final notifService = PrayerNotificationService(
          client: fakeClient,
          calculationService: const _LocalDeterministicCalculationService(),
          prayerSettingsService: prayerSettingsService,
          notificationSettingsService: notifSettingsService,
          clock: () => DateTime(2026, 3, 20, 4, 0),
        );

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerSettingsPage(
              settingsService: prayerSettingsService,
              notificationSettingsService: notifSettingsService,
              notificationService: notifService,
              initialLatitude: 21.4225,
              initialLongitude: 39.8262,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Initially disabled; Sunrise never appears anywhere as a toggle
        expect(find.text('الشروق'), findsNothing);
        expect(find.byKey(const Key('prayer_toggle_sunrise')), findsNothing);
        expect(fakeClient.requestPermissionCalls, equals(0));

        // Tap master switch -> Arabic rationale dialog must appear BEFORE OS permission request
        await tester.tap(
          find.byKey(const Key('prayer_notifications_master_switch')),
        );
        await tester.pumpAndSettle();

        expect(find.text('إذن تنبيهات مواقيت الصلاة'), findsOneWidget);
        expect(fakeClient.requestPermissionCalls, equals(0));

        // Confirm rationale -> OS permission requested & 5 obligatory prayer toggles appear
        await tester.tap(find.byKey(const Key('permission_rationale_confirm')));
        await tester.pumpAndSettle();

        expect(fakeClient.requestPermissionCalls, equals(1));
        expect(notifSettingsService.currentSettings.enabled, isTrue);
        expect(fakeClient.scheduledDetails.length, equals(35));

        expect(find.byKey(const Key('prayer_toggle_fajr')), findsOneWidget);
        expect(find.byKey(const Key('prayer_toggle_dhuhr')), findsOneWidget);
        expect(find.byKey(const Key('prayer_toggle_asr')), findsOneWidget);
        expect(find.byKey(const Key('prayer_toggle_maghrib')), findsOneWidget);
        expect(find.byKey(const Key('prayer_toggle_isha')), findsOneWidget);
        expect(find.text('الشروق'), findsNothing);

        // Disable Asr independently
        await tester.ensureVisible(find.byKey(const Key('prayer_toggle_asr')));
        await tester.tap(find.byKey(const Key('prayer_toggle_asr')));
        await tester.pumpAndSettle();
        expect(notifSettingsService.currentSettings.asr, isFalse);
        expect(fakeClient.scheduledDetails.length, equals(28)); // 7 * 4

        // Switch sound mode to silent
        await tester.tap(find.byKey(const Key('sound_mode_silent')));
        await tester.pumpAndSettle();
        expect(
          notifSettingsService.currentSettings.soundMode,
          equals(PrayerNotificationSound.silent),
        );
        expect(
          fakeClient.scheduledDetails[5000]!.android!.channelId,
          equals(PrayerNotificationService.silentChannelId),
        );
      },
    );

    testWidgets(
      'denying OS notification permission keeps notifications disabled and shows friendly denied banner',
      (WidgetTester tester) async {
        setLargeSurface(tester);
        final prayerSettingsService = PrayerSettingsService();
        final notifSettingsService = PrayerNotificationSettingsService();
        final fakeClient = _FakeUiNotificationClient(
          permissionGranted: false,
          nextRequestResult: false,
        );
        final notifService = PrayerNotificationService(
          client: fakeClient,
          prayerSettingsService: prayerSettingsService,
          notificationSettingsService: notifSettingsService,
        );

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerSettingsPage(
              settingsService: prayerSettingsService,
              notificationSettingsService: notifSettingsService,
              notificationService: notifService,
              initialLatitude: 21.4225,
              initialLongitude: 39.8262,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('prayer_notifications_master_switch')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('permission_rationale_confirm')));
        await tester.pumpAndSettle();

        expect(fakeClient.requestPermissionCalls, equals(1));
        expect(notifSettingsService.currentSettings.enabled, isFalse);
        expect(fakeClient.scheduledDetails, isEmpty);
        expect(
          find.byKey(const Key('permission_denied_banner')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('open_device_settings_button')),
          findsOneWidget,
        );

        // User explicitly taps "فتح إعدادات الجهاز"
        await tester.tap(find.byKey(const Key('open_device_settings_button')));
        await tester.pumpAndSettle();
        expect(fakeClient.openAppSettingsCalls, equals(1));
      },
    );

    testWidgets(
      'navigating from PrayerTimesPage settings button to PrayerSettingsPage updates displayed prayer settings on return',
      (WidgetTester tester) async {
        setLargeSurface(tester);
        final prayerSettingsService = PrayerSettingsService();
        final notifSettingsService = PrayerNotificationSettingsService();
        final fakeClient = _FakeUiNotificationClient(permissionGranted: false);
        final notifService = PrayerNotificationService(
          client: fakeClient,
          prayerSettingsService: prayerSettingsService,
          notificationSettingsService: notifSettingsService,
        );
        final locationService = PrayerLocationService(
          client: _FakeLocationClient(),
        );

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerTimesPage(
              settingsService: prayerSettingsService,
              locationService: locationService,
              notificationSettingsService: notifSettingsService,
              notificationService: notifService,
              clock: () => DateTime(2026, 3, 20, 8, 0),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('المذهب: الشافعي (الجمهور)'), findsOneWidget);

        await tester.tap(find.byKey(const Key('prayer_settings_button')));
        await tester.pumpAndSettle();

        expect(find.text('إعدادات الصلاة'), findsOneWidget);

        await tester.tap(find.byKey(const Key('madhab_hanafi')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('prayer_settings_back_button')));
        await tester.pumpAndSettle();

        expect(find.text('المذهب: الحنفي'), findsOneWidget);
      },
    );

    testWidgets(
      'coordinate cache persistence failure displays error snackbar, avoids false scheduled status, and keeps page usable',
      (WidgetTester tester) async {
        setLargeSurface(tester);
        final prayerSettingsService = PrayerSettingsService();
        final failingCachePrefs = _FailingCoordinateCachePrefs();
        final notifSettingsService = PrayerNotificationSettingsService(
          preferencesProvider: () async => failingCachePrefs,
        );
        final fakeClient = _FakeUiNotificationClient(
          permissionGranted: false,
          nextRequestResult: true,
        );
        final notifService = PrayerNotificationService(
          client: fakeClient,
          calculationService: const _LocalDeterministicCalculationService(),
          prayerSettingsService: prayerSettingsService,
          notificationSettingsService: notifSettingsService,
          clock: () => DateTime(2026, 3, 20, 4, 0),
        );

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerSettingsPage(
              settingsService: prayerSettingsService,
              notificationSettingsService: notifSettingsService,
              notificationService: notifService,
              initialLatitude: 21.4225,
              initialLongitude: 39.8262,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('prayer_notifications_master_switch')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('permission_rationale_confirm')));
        await tester.pumpAndSettle();

        // No unhandled exception escaped and error snackbar is shown
        expect(tester.takeException(), isNull);
        expect(
          find.text('تعذّر حفظ إحداثيات الموقع محلياً لجدولة تنبيهات الصلاة'),
          findsOneWidget,
        );

        // Must NOT falsely schedule notifications or hide missing-coordinates guidance
        expect(fakeClient.scheduledDetails, isEmpty);
        expect(find.byKey(const Key('missing_coordinates_note')), findsOneWidget);

        // Page remains usable (can still toggle Madhab & switch master off cleanly)
        await tester.tap(find.byKey(const Key('madhab_hanafi')));
        await tester.pumpAndSettle();
        expect(
          prayerSettingsService.currentSettings.madhab,
          equals(Madhab.hanafi),
        );
      },
    );

    testWidgets(
      'cancelling Arabic permission rationale leaves notifications disabled without requesting OS permission',
      (WidgetTester tester) async {
        setLargeSurface(tester);
        final prayerSettingsService = PrayerSettingsService();
        final notifSettingsService = PrayerNotificationSettingsService();
        final fakeClient = _FakeUiNotificationClient(permissionGranted: false);
        final notifService = PrayerNotificationService(
          client: fakeClient,
          prayerSettingsService: prayerSettingsService,
          notificationSettingsService: notifSettingsService,
        );

        await tester.pumpWidget(
          wrapWithBundle(
            PrayerSettingsPage(
              settingsService: prayerSettingsService,
              notificationSettingsService: notifSettingsService,
              notificationService: notifService,
              initialLatitude: 21.4225,
              initialLongitude: 39.8262,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('prayer_notifications_master_switch')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('permission_rationale_cancel')));
        await tester.pumpAndSettle();

        expect(fakeClient.requestPermissionCalls, equals(0));
        expect(notifSettingsService.currentSettings.enabled, isFalse);
        expect(fakeClient.scheduledDetails, isEmpty);
      },
    );
  });
}

