import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:camera/camera.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import 'screens/auth/auth_wrapper.dart';
import 'services/cart_service.dart';
import 'services/inventory_service.dart';
import 'screens/chatbot/chatbot_screen.dart';
import 'config/config.dart';
import 'config/active_tenant.g.dart';
import 'config/web_theme_listener_stub.dart'
    if (dart.library.html) 'config/web_theme_listener_web.dart';

List<CameraDescription> cameras = [];

// ---------------------------------------------------------------------------
// Active brand — loaded from generated configuration at build time.
// ---------------------------------------------------------------------------
const BrandConfig _activeBrand = activeBrandConfig;

Future<void> _initDynamicTheme() async {
  const tenantId = String.fromEnvironment('TENANT_ID', defaultValue: 'qless');
  if (tenantId == 'qless') {
    BrandConfig.active = BrandConfig.qless();
    return; // Use default build-time activeBrandConfig
  }

  // 1. Try to load cached config from SharedPreferences (for instant offline startup)
  try {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('cached_tenant_config_$tenantId');
    if (cached != null) {
      final decoded = json.decode(cached) as Map<String, dynamic>;
      BrandConfig.active = BrandConfig.fromJson(decoded);
      debugPrint('[ThemeService] Loaded cached tenant config for: $tenantId');
    } else {
      // Fallback presets if offline and no cache
      if (tenantId == 'lulu') BrandConfig.active = BrandConfig.lulu();
      if (tenantId == 'carrefour') BrandConfig.active = BrandConfig.carrefour();
    }
  } catch (e) {
    debugPrint('[ThemeService] Error loading cached tenant config: $e');
  }

  // 2. Fetch the latest config from Supabase in the background/startup
  try {
    final response = await Supabase.instance.client
        .from('tenants')
        .select()
        .eq('tenant_id', tenantId)
        .maybeSingle();

    if (response != null && response['is_active'] == true) {
      final config = BrandConfig.fromJson(response);
      BrandConfig.active = config;
      // Cache it for the next startup
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'cached_tenant_config_$tenantId',
        json.encode(response),
      );
      debugPrint(
        '[ThemeService] Successfully synchronized and cached theme config for: $tenantId',
      );
    }
  } catch (e) {
    debugPrint('[ThemeService] Failed to synchronize tenant config: $e');
  }
}

Future<void> main() async {
  BrandConfig.active = _activeBrand;
  WidgetsFlutterBinding.ensureInitialized();

  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera initialization error: $e');
  }

  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint('Could not load .env file: $e');
  }

  // Initialize Supabase using values from .env if valid and non-placeholder
  final rawSupabaseUrl = dotenv.env['SUPABASE_URL']?.trim() ?? '';
  final rawSupabaseKey = dotenv.env['SUPABASE_ANON_KEY']?.trim() ?? '';
  final parsedSupabaseUrl = Uri.tryParse(rawSupabaseUrl);
  final isSupabaseValid = rawSupabaseUrl.isNotEmpty &&
      !rawSupabaseUrl.contains('<your-project-ref>') &&
      !rawSupabaseUrl.contains('<') &&
      !rawSupabaseUrl.contains('>') &&
      parsedSupabaseUrl != null &&
      parsedSupabaseUrl.hasAbsolutePath &&
      parsedSupabaseUrl.host.isNotEmpty;

  if (isSupabaseValid && rawSupabaseKey.isNotEmpty) {
    try {
      await Supabase.initialize(
        url: rawSupabaseUrl,
        publishableKey: rawSupabaseKey,
      );
      debugPrint('[Main] Supabase initialized successfully.');
    } catch (e) {
      debugPrint('Supabase initialization error: $e');
    }
  } else {
    debugPrint(
      '[Main] Skipping Supabase initialization: Unconfigured or placeholder SUPABASE_URL.',
    );
  }

  // Load and cache tenant theme if specified via dart-define
  await _initDynamicTheme();

  // Pre-load dynamic product catalog, cart session, and chatbot history in parallel before rendering.
  await Future.wait([
    InventoryService().syncCatalogWithSupabase(),
    CartService().load(),
    ChatbotScreen.preloadHistory(),
  ]);

  runApp(MainApp(cameras: cameras));
}

class MainApp extends StatefulWidget {
  final List<CameraDescription> cameras;

  const MainApp({super.key, required this.cameras});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  @override
  void initState() {
    super.initState();
    initWebThemeListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: BrandConfig.active.identity.appName,
      debugShowCheckedModeBanner: false,
      theme: BrandConfig.active.buildTheme(),
      home: AuthWrapper(cameras: widget.cameras),
    );
  }
}
