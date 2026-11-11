import 'package:adhkar/core/services/notification_service.dart';
import 'package:adhkar/features/adhkar/presentation/managers/settings_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotificationService Scheduling Tests', () {
    setUpAll(() {
      tz.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation('UTC'));
    });

    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test(
      'scheduleMorningNotification calculates target time 2 minutes in future correctly',
      () async {
        final now = tz.TZDateTime.now(tz.local);
        final futureTime = now.add(const Duration(minutes: 2));

        final testTime = TimeOfDay(
          hour: futureTime.hour,
          minute: futureTime.minute,
        );
        await SettingsManager.setMorningTime(testTime);

        expect(SettingsManager.morningTime.value, equals(testTime));
        expect(SettingsManager.morningTime.value.hour, equals(futureTime.hour));
        expect(
          SettingsManager.morningTime.value.minute,
          equals(futureTime.minute),
        );
      },
    );

    test(
      'scheduleEveningNotification calculates target time 2 minutes in future correctly',
      () async {
        final now = tz.TZDateTime.now(tz.local);
        final futureTime = now.add(const Duration(minutes: 2));

        final testTime = TimeOfDay(
          hour: futureTime.hour,
          minute: futureTime.minute,
        );
        await SettingsManager.setEveningTime(testTime);

        expect(SettingsManager.eveningTime.value, equals(testTime));
        expect(SettingsManager.eveningTime.value.hour, equals(futureTime.hour));
        expect(
          SettingsManager.eveningTime.value.minute,
          equals(futureTime.minute),
        );
      },
    );
  });

  group('Existing Notification Safety Regression Tests', () {
    const MethodChannel notifChannel = MethodChannel(
      'dexterous.com/flutter/local_notifications',
    );
    const MethodChannel tzChannel = MethodChannel('flutter_timezone');

    late List<MethodCall> methodCalls;
    late bool iosPermissionGranted;
    late bool androidNotificationsEnabled;
    late bool androidCanExactAlarms;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      NotificationService.resetForTesting();
      SettingsManager.morningReminder.value = true;
      SettingsManager.eveningReminder.value = true;
      SettingsManager.dailyReminder.value = true;

      methodCalls = <MethodCall>[];
      iosPermissionGranted = false;
      androidNotificationsEnabled = true;
      androidCanExactAlarms = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(tzChannel, (MethodCall call) async {
        if (call.method == 'getLocalTimezone') {
          return 'UTC';
        }
        return null;
      });

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notifChannel, (MethodCall call) async {
        methodCalls.add(call);
        switch (call.method) {
          case 'initialize':
          case 'createNotificationChannel':
          case 'cancel':
          case 'cancelAll':
          case 'zonedSchedule':
            return true;
          case 'checkPermissions':
            return <String, bool>{
              'isEnabled': iosPermissionGranted,
              'isAlertEnabled': iosPermissionGranted,
              'isSoundEnabled': iosPermissionGranted,
              'isBadgeEnabled': iosPermissionGranted,
              'isProvisionalEnabled': false,
              'isCriticalEnabled': false,
            };
          case 'requestPermissions':
            return iosPermissionGranted;
          case 'areNotificationsEnabled':
            return androidNotificationsEnabled;
          case 'canScheduleExactNotifications':
            return androidCanExactAlarms;
          case 'requestExactAlarmsPermission':
            return androidCanExactAlarms;
          default:
            return null;
        }
      });
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      NotificationService.resetForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notifChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(tzChannel, null);
    });

    test(
      'iOS NotificationService.init and startup sync do NOT request notification permission',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        IOSFlutterLocalNotificationsPlugin.registerWith();
        iosPermissionGranted = false;

        await NotificationService.init();

        expect(
          methodCalls.where((c) => c.method == 'initialize').length,
          equals(1),
        );
        expect(
          methodCalls.where((c) => c.method == 'checkPermissions').length,
          equals(1),
        );
        expect(
          methodCalls.where((c) => c.method == 'requestPermissions'),
          isEmpty,
        );
        expect(methodCalls.where((c) => c.method == 'cancelAll'), isEmpty);

        final cancelledIds = methodCalls
            .where((c) => c.method == 'cancel')
            .map((c) => c.arguments as int)
            .toList();
        expect(
          cancelledIds,
          unorderedEquals(NotificationService.adhkarNotificationIds),
        );
        for (int prayerId = 5000; prayerId <= 5069; prayerId++) {
          expect(cancelledIds, isNot(contains(prayerId)));
        }
      },
    );

    test(
      'iOS SettingsManager.syncNotificationPermissionsWithOs (lifecycle resume) does NOT request permission or call cancelAll',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        IOSFlutterLocalNotificationsPlugin.registerWith();
        iosPermissionGranted = false;

        await SettingsManager.syncNotificationPermissionsWithOs();

        expect(
          methodCalls.where((c) => c.method == 'checkPermissions').length,
          equals(1),
        );
        expect(
          methodCalls.where((c) => c.method == 'requestPermissions'),
          isEmpty,
        );
        expect(methodCalls.where((c) => c.method == 'cancelAll'), isEmpty);

        final cancelledIds = methodCalls
            .where((c) => c.method == 'cancel')
            .map((c) => c.arguments as int)
            .toSet();
        expect(cancelledIds, equals(<int>{1001, 1002, 2001, 2002, 2003}));
      },
    );

    test(
      'Adhkar cancellation never calls cancelAll and never cancels prayer IDs (5000..5069)',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        AndroidFlutterLocalNotificationsPlugin.registerWith();
        androidNotificationsEnabled = false;

        await NotificationService.cancelAdhkarNotifications();
        await NotificationService.cancelAll();
        await NotificationService.syncSchedulesWithOsState();

        expect(methodCalls.where((c) => c.method == 'cancelAll'), isEmpty);
        final cancelledIds = methodCalls
            .where((c) => c.method == 'cancel')
            .map((c) => (c.arguments as Map)['id'] as int)
            .toSet();
        expect(cancelledIds, equals(<int>{1001, 1002, 2001, 2002, 2003}));
        for (int prayerId = 5000; prayerId <= 5069; prayerId++) {
          expect(cancelledIds, isNot(contains(prayerId)));
        }
      },
    );

    test(
      'Android startup sync preserves Adhkar IDs, uses read-only exact-alarm check, and falls back to inexact scheduling',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        AndroidFlutterLocalNotificationsPlugin.registerWith();
        androidNotificationsEnabled = true;
        androidCanExactAlarms = false;

        await NotificationService.init();

        expect(
          methodCalls
              .where((c) => c.method == 'areNotificationsEnabled')
              .length,
          equals(1),
        );
        expect(
          methodCalls
              .where((c) => c.method == 'canScheduleExactNotifications')
              .length,
          greaterThan(0),
        );
        // Must NEVER invoke requestExactAlarmsPermission automatically on startup
        expect(
          methodCalls.where((c) => c.method == 'requestExactAlarmsPermission'),
          isEmpty,
        );
        expect(methodCalls.where((c) => c.method == 'cancelAll'), isEmpty);

        final scheduledCalls = methodCalls
            .where((c) => c.method == 'zonedSchedule')
            .toList();
        expect(
          scheduledCalls
              .map((c) => (c.arguments as Map)['id'] as int)
              .toSet(),
          equals(<int>{1001, 1002, 2001, 2002, 2003}),
        );
        for (final call in scheduledCalls) {
          final specifics =
              (call.arguments as Map)['platformSpecifics'] as Map;
          expect(
            specifics['scheduleMode'],
            equals(AndroidScheduleMode.inexactAllowWhileIdle.name),
          );
        }
      },
    );
  });
}
