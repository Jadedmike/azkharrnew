import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import '../../config/theme/app_assets.dart';
import '../../features/adhkar/presentation/managers/settings_manager.dart';

/// Production-ready service responsible for managing local system notifications,
/// OS notification channels, exact alarm permission checks, Doze mode handling,
/// boot persistence, timezone scheduling, and immediate test triggers.
class NotificationService {
  NotificationService._();

  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static bool _isInitialized = false;

  // Notification IDs
  static const int _idMorning = 1001;
  static const int _idEvening = 1002;
  static const int _idTestImmediate = 9999;
  static const List<int> _idRandomDhikrs = [2001, 2002, 2003];

  /// All scheduled Adhkar notification IDs owned by [NotificationService].
  static const List<int> adhkarNotificationIds = <int>[
    _idMorning,
    _idEvening,
    2001,
    2002,
    2003,
  ];

  @visibleForTesting
  static void resetForTesting() {
    _isInitialized = false;
  }

  // Channel IDs & Configurations
  static const String _channelIdReminders = 'athkar_reminders_channel';
  static const String _channelNameReminders = 'تنبيهات الأذكار اليومية';
  static const String _channelDescReminders =
      'تنبيهات أذكار الصباح والمساء بحجم وأولوية عالية مع الصوت والاهتزاز';

  static const String _channelIdRandom = 'adhkar_random_channel';
  static const String _channelNameRandom = 'تذكير الأدعية والأذكار';
  static const String _channelDescRandom =
      'تذكير دوري عشوائي بالأدعية والأذكار خلال اليوم';

  /// Initialize notification plugin, timezones, notification channels, and sync schedules.
  static Future<void> init() async {
    if (_isInitialized) return;

    // 1. Initialize Timezone Database & Local Location
    try {
      tz.initializeTimeZones();
      final String timeZoneName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timeZoneName));
    } catch (_) {
      try {
        tz.setLocalLocation(tz.getLocation('UTC'));
      } catch (_) {}
    }

    // 2. Platform Initialization Settings
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings initializationSettingsDarwin =
        DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
    );

    await _notificationsPlugin.initialize(initializationSettings);

    // 3. Create Dedicated Android Notification Channels (Android 8.0+)
    await _createNotificationChannels();

    _isInitialized = true;

    // 4. Synchronize user preferences and reschedule alarms upon app startup
    await syncSchedulesWithOsState();
  }

  /// Create explicit high-importance notification channels on Android 8.0+
  static Future<void> _createNotificationChannels() async {
    try {
      final androidImpl = _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

      if (androidImpl != null) {
        // High-importance channel for Morning & Evening Reminders
        final AndroidNotificationChannel remindersChannel =
            AndroidNotificationChannel(
              _channelIdReminders,
              _channelNameReminders,
              description: _channelDescReminders,
              importance: Importance.high,
              playSound: true,
              enableVibration: true,
              vibrationPattern: Int64List.fromList([0, 1000, 500, 1000]),
              enableLights: true,
              ledColor: const Color(0xFFC5A059),
            );

        // High-importance channel for Daily Periodic Supplications
        final AndroidNotificationChannel randomChannel =
            AndroidNotificationChannel(
              _channelIdRandom,
              _channelNameRandom,
              description: _channelDescRandom,
              importance: Importance.high,
              playSound: true,
              enableVibration: true,
              vibrationPattern: Int64List.fromList([0, 500, 250, 500]),
              enableLights: true,
              ledColor: const Color(0xFF4E5B4E),
            );

        await androidImpl.createNotificationChannel(remindersChannel);
        await androidImpl.createNotificationChannel(randomChannel);
      }
    } catch (_) {}
  }

  /// Check if the OS notification permission is currently granted without
  /// triggering a permission prompt.
  static Future<bool> isPermissionGranted() async {
    try {
      final androidImpl = _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidImpl != null) {
        final bool? granted = await androidImpl.areNotificationsEnabled();
        return granted ?? false;
      }

      final iosImpl = _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (iosImpl != null) {
        final NotificationsEnabledOptions? options =
            await iosImpl.checkPermissions();
        return (options?.isEnabled ?? false) ||
            (options?.isAlertEnabled ?? false) ||
            (options?.isProvisionalEnabled ?? false);
      }
    } catch (_) {}

    return true;
  }

  /// Explicitly request OS notification permission from the user.
  static Future<bool> requestPermission() async {
    try {
      final androidImpl = _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidImpl != null) {
        final bool? granted =
            await androidImpl.requestNotificationsPermission();
        return granted ?? false;
      }

      final iosImpl = _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (iosImpl != null) {
        final bool? granted = await iosImpl.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        return granted ?? false;
      }
    } catch (_) {}

    return true;
  }

  /// Check and request exact alarm permission if needed (Android 12/13/14+).
  static Future<bool> requestExactAlarmsPermission() async {
    try {
      final androidImpl = _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidImpl != null) {
        final bool? granted = await androidImpl.requestExactAlarmsPermission();
        return granted ?? true;
      }
    } catch (_) {}
    return true;
  }

  /// Open system settings for exact alarm permission if missing (Android 12+).
  static Future<void> openExactAlarmSettings() async {
    await requestExactAlarmsPermission();
  }

  /// Read-only check for whether exact alarm scheduling is currently
  /// permitted on Android 12+ without launching OS settings screens.
  static Future<bool> canScheduleExactNotifications() async {
    try {
      final androidImpl = _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidImpl != null) {
        final bool? canExact = await androidImpl.canScheduleExactNotifications();
        return canExact ?? false;
      }
    } catch (_) {}
    return true;
  }

  /// Determine the appropriate scheduling mode dynamically using a read-only
  /// exact-alarm capability check.
  ///
  /// Uses [AndroidScheduleMode.exactAllowWhileIdle] when permitted, or falls
  /// back safely to [AndroidScheduleMode.inexactAllowWhileIdle] without
  /// launching system settings screens.
  static Future<AndroidScheduleMode> _determineScheduleMode() async {
    try {
      final bool canExact = await canScheduleExactNotifications();
      if (canExact) {
        return AndroidScheduleMode.exactAllowWhileIdle;
      }
    } catch (_) {}
    return AndroidScheduleMode.inexactAllowWhileIdle;
  }

  /// Synchronize scheduled notifications based on user settings and real OS permission state.
  static Future<void> syncSchedulesWithOsState() async {
    final bool hasPermission = await isPermissionGranted();

    if (!hasPermission) {
      await cancelAdhkarNotifications();
      return;
    }

    // Handle Morning Reminder
    if (SettingsManager.morningReminder.value) {
      await scheduleMorningNotification();
    } else {
      await cancelMorning();
    }

    // Handle Evening Reminder
    if (SettingsManager.eveningReminder.value) {
      await scheduleEveningNotification();
    } else {
      await cancelEvening();
    }

    // Handle Daily Random Reminders
    if (SettingsManager.dailyReminder.value) {
      await scheduleRandomDhikrNotifications();
    } else {
      await cancelDaily();
    }
  }

  /// Schedule Daily Morning Notification
  static Future<void> scheduleMorningNotification({
    int? hour,
    int? minute,
  }) async {
    try {
      final int targetHour = hour ?? SettingsManager.morningTime.value.hour;
      final int targetMinute =
          minute ?? SettingsManager.morningTime.value.minute;

      await cancelMorning();

      final tz.TZDateTime scheduledDate = _nextInstanceOfTime(
        targetHour,
        targetMinute,
      );
      final AndroidScheduleMode mode = await _determineScheduleMode();

      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
            _channelIdReminders,
            _channelNameReminders,
            channelDescription: _channelDescReminders,
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            styleInformation: BigTextStyleInformation(''),
          );

      const NotificationDetails details = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: true,
        ),
      );

      await _notificationsPlugin.zonedSchedule(
        _idMorning,
        'ذِكْر',
        'حان وقت أذكار الصباح',
        scheduledDate,
        details,
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (_) {}
  }

  /// Schedule Daily Evening Notification
  static Future<void> scheduleEveningNotification({
    int? hour,
    int? minute,
  }) async {
    try {
      final int targetHour = hour ?? SettingsManager.eveningTime.value.hour;
      final int targetMinute =
          minute ?? SettingsManager.eveningTime.value.minute;

      await cancelEvening();

      final tz.TZDateTime scheduledDate = _nextInstanceOfTime(
        targetHour,
        targetMinute,
      );
      final AndroidScheduleMode mode = await _determineScheduleMode();

      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
            _channelIdReminders,
            _channelNameReminders,
            channelDescription: _channelDescReminders,
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            styleInformation: BigTextStyleInformation(''),
          );

      const NotificationDetails details = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: true,
        ),
      );

      await _notificationsPlugin.zonedSchedule(
        _idEvening,
        'ذِكْر',
        'حان وقت أذكار المساء',
        scheduledDate,
        details,
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (_) {}
  }

  /// Schedule Random Daily Dhikr Notifications using existing JSON content
  static Future<void> scheduleRandomDhikrNotifications() async {
    try {
      final List<String> validDhikrs = await _loadValidDhikrsFromAssets();
      if (validDhikrs.isEmpty) return;

      final random = Random();
      final times = [
        const TimeOfDay(hour: 13, minute: 0),
        const TimeOfDay(hour: 16, minute: 30),
        const TimeOfDay(hour: 21, minute: 0),
      ];

      final AndroidScheduleMode mode = await _determineScheduleMode();

      for (int i = 0; i < times.length; i++) {
        final time = times[i];
        final int id = _idRandomDhikrs[i];
        final String selectedDhikr =
            validDhikrs[random.nextInt(validDhikrs.length)];
        final String truncatedBody = _truncateText(selectedDhikr, 90);

        final tz.TZDateTime scheduledDate = _nextInstanceOfTime(
          time.hour,
          time.minute,
        );

        const AndroidNotificationDetails androidDetails =
            AndroidNotificationDetails(
              _channelIdRandom,
              _channelNameRandom,
              channelDescription: _channelDescRandom,
              importance: Importance.high,
              priority: Priority.high,
              playSound: true,
              enableVibration: true,
              styleInformation: BigTextStyleInformation(''),
            );

        const NotificationDetails details = NotificationDetails(
          android: androidDetails,
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBadge: true,
          ),
        );

        await _notificationsPlugin.zonedSchedule(
          id,
          '✨ ذكر ودعاء',
          truncatedBody,
          scheduledDate,
          details,
          androidScheduleMode: mode,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.time,
        );
      }
    } catch (_) {}
  }

  /// Triggers an immediate test notification to instantly verify device sound & display.
  static Future<void> testImmediateNotification() async {
    try {
      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
            _channelIdReminders,
            _channelNameReminders,
            channelDescription: _channelDescReminders,
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            styleInformation: BigTextStyleInformation(''),
          );

      const NotificationDetails details = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: true,
        ),
      );

      await _notificationsPlugin.show(
        _idTestImmediate,
        '🔔 تجربة التنبيهات الفورية',
        'تم تفعيل التنبيهات بنجاح في تطبيق ذكر 🤍',
        details,
      );
    } catch (_) {}
  }

  /// Cancel Morning Notification
  static Future<void> cancelMorning() async {
    try {
      await _notificationsPlugin.cancel(_idMorning);
    } catch (_) {}
  }

  /// Cancel Evening Notification
  static Future<void> cancelEvening() async {
    try {
      await _notificationsPlugin.cancel(_idEvening);
    } catch (_) {}
  }

  /// Cancel Daily Random Notifications
  static Future<void> cancelDaily() async {
    try {
      for (final id in _idRandomDhikrs) {
        await _notificationsPlugin.cancel(id);
      }
    } catch (_) {}
  }

  /// Cancel only Adhkar scheduled notification IDs (`1001`, `1002`, `2001`,
  /// `2002`, `2003`) without disturbing notifications owned by other features.
  static Future<void> cancelAdhkarNotifications() async {
    for (final id in adhkarNotificationIds) {
      try {
        await _notificationsPlugin.cancel(id);
      } catch (_) {}
    }
  }

  /// Cancel all Adhkar notifications owned by this service.
  ///
  /// Targets only [adhkarNotificationIds] rather than calling plugin-wide
  /// `cancelAll()` so notifications owned by other features (such as prayer
  /// notifications) are never deleted.
  static Future<void> cancelAll() => cancelAdhkarNotifications();

  /// Load valid Dhikr texts from existing JSON assets only.
  static Future<List<String>> _loadValidDhikrsFromAssets() async {
    final List<String> jsonPaths = [
      AppAssets.jsonMorning,
      AppAssets.jsonEvening,
      AppAssets.jsonAfterPrayer,
      AppAssets.jsonSleep,
      AppAssets.jsonTravel,
      AppAssets.jsonQuranDuas,
      AppAssets.jsonPropheticDuas,
      AppAssets.jsonForgivenessDuas,
    ];

    final List<String> dhikrs = [];

    for (final path in jsonPaths) {
      try {
        final String jsonString = await rootBundle.loadString(path);
        final List<dynamic> parsed = json.decode(jsonString);
        for (final item in parsed) {
          if (item is Map) {
            final String text =
                (item['text'] ?? item['content'] ?? item['dhikr'] ?? '')
                    .toString()
                    .trim();
            if (text.isNotEmpty) {
              dhikrs.add(text);
            }
          }
        }
      } catch (_) {}
    }

    return dhikrs;
  }

  /// Safely truncate long text for notification display without breaking Arabic Unicode.
  static String _truncateText(String text, int maxLength) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= maxLength) return cleaned;

    final String sub = cleaned.substring(0, maxLength);
    final int lastSpace = sub.lastIndexOf(' ');
    if (lastSpace > 30) {
      return '${sub.substring(0, lastSpace)}...';
    }
    return '$sub...';
  }

  /// Calculate next instance of a specific hour and minute in current timezone.
  static tz.TZDateTime _nextInstanceOfTime(int hour, int minute) {
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime scheduledDate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }
    return scheduledDate;
  }
}
