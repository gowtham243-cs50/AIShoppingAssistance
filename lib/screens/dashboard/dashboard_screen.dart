import 'dart:io';
import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'widgets/cart_item.dart';
import '../chatbot/chatbot_screen.dart';
import '../../models/cart_item_model.dart';
import '../../models/fulfillment_option.dart';
import '../../services/chromadb_client.dart';
import '../../services/cart_service.dart';
import '../../services/inventory_service.dart';
import '../../services/product_detection_service.dart';
import '../../services/chat_agent_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'widgets/dashboard_app_bar.dart';
import 'widgets/camera_viewport.dart';
import 'widgets/bottom_nav_bar.dart';
import 'widgets/checkout_bar.dart';
import 'widgets/dashboard_sheets.dart';
import '../profile/profile_page.dart';
import 'notifications_page.dart';
import '../inventory/inventory_screen.dart';
import '../../services/notification_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../utils/web_blur_helper_stub.dart'
    if (dart.library.js_interop) '../../utils/web_blur_helper_web.dart';

class DashboardScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const DashboardScreen({super.key, required this.cameras});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final ChromaDbClient _chromaClient = ChromaDbClient();
  final ProductDetectionService _detectionService =
      HuggingFaceProxyDetectionService();
  late AnimationController _cursorController;
  late AnimationController _cartExpandController;
  String? _profilePicBase64;
  bool _hasNotifications = false;

  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isSearchingImage = false;

  // Cart database service (session-scoped, resets on checkout)
  final CartService _cartService = CartService();
  bool _isCheckingOut = false;

  DbConnectionStatus _dbStatus = DbConnectionStatus.unknown;

  // Background scanning & locking state variables
  Timer? _backgroundScanTimer;
  bool _isCameraBusy = false;
  CartItemModel? _cachedDetectedItem;
  DateTime? _cachedDetectionTime;
  bool _isConfirmSheetOpen = false;
  bool _isDashboardActive = true;
  // Timestamp tracking to prevent stale background scan race conditions
  DateTime? _lastActionTime;
  DateTime? _backgroundScanPauseUntil;

  @override
  void initState() {
    super.initState();
    WebBlurHelper.initialize();
    _lastActionTime = DateTime.now();
    WidgetsBinding.instance.addObserver(this);
    _cursorController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);

    _cartExpandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _initializeCamera();
    _refreshDbStatus();
    _startBackgroundScanning();
    _loadProfilePic();
    _checkNotificationsStatus();
  }

  Future<void> _loadProfilePic() async {
    try {
      final email = Supabase.instance.client.auth.currentUser?.email ?? 'Guest';
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('profile_pic_$email');
      if (mounted) {
        setState(() {
          _profilePicBase64 = saved;
        });
      }

      final user = Supabase.instance.client.auth.currentUser;
      final supabasePic = user?.userMetadata?['profile_pic'] as String?;
      if (supabasePic != null && supabasePic != saved) {
        await prefs.setString('profile_pic_$email', supabasePic);
        if (mounted) {
          setState(() {
            _profilePicBase64 = supabasePic;
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading profile pic in dashboard: $e');
    }
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) return;

    // Clean up any existing controller to prevent leaks and camera locking
    if (_cameraController != null) {
      try {
        await _cameraController!.dispose();
      } catch (e) {
        debugPrint("Error disposing camera controller: $e");
      }
      _cameraController = null;
    }

    const resolution = kIsWeb ? ResolutionPreset.medium : ResolutionPreset.low;
    _cameraController = CameraController(
      widget.cameras[0],
      resolution,
      enableAudio: false,
      imageFormatGroup: kIsWeb ? null : ImageFormatGroup.jpeg,
    );

    try {
      await _cameraController!.initialize();

      // Laptop webcams or web/desktop platforms generally don't support torch/flash.
      // We check if we are on a mobile platform (Android or iOS) first.
      final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
      if (isMobile) {
        try {
          await _cameraController!.setFlashMode(FlashMode.off);
        } catch (flashError) {
          debugPrint(
            "Failed to set flash mode to off (not supported): $flashError",
          );
        }
      }

      if (mounted) {
        setState(() => _isCameraInitialized = true);
      }
    } catch (e) {
      debugPrint("Camera initialization failed: $e");
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopBackgroundScanning();
    _cameraController?.dispose();
    _cursorController.dispose();
    _cartExpandController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _cameraController;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopBackgroundScanning();
      if (cameraController != null) {
        setState(() => _isCameraInitialized = false);
        cameraController.dispose();
        _cameraController = null;
      }
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
      _startBackgroundScanning();
    }
  }

  void _startBackgroundScanning() {
    if (!_isDashboardActive) return;
    _backgroundScanTimer?.cancel();
    _backgroundScanTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _performBackgroundScan();
    });
    debugPrint("[DashboardScreen] Background scanning started.");
  }

  void _stopBackgroundScanning() {
    _backgroundScanTimer?.cancel();
    _backgroundScanTimer = null;
    debugPrint("[DashboardScreen] Background scanning stopped.");
  }

  Future<void> _performBackgroundScan() async {
    // Requirements:
    // 1. Camera must be initialized and NOT busy
    // 2. Cart must be collapsed (expanded controller value == 0)
    // 3. Shutter must NOT be actively searching/loading a manual scan
    // 4. Confirmation sheet must NOT be open
    // 5. Background scanning must not be paused
    if (_backgroundScanPauseUntil != null &&
        DateTime.now().isBefore(_backgroundScanPauseUntil!)) {
      return;
    }
    if (!_isCameraInitialized || _cameraController == null || _isCameraBusy) {
      return;
    }
    if (_cartExpandController.value > 0.0) return;
    if (_isSearchingImage) return;
    if (_isConfirmSheetOpen) return;

    _isCameraBusy = true;

    final DateTime captureTime = DateTime.now();
    XFile? capturedPhoto;
    try {
      capturedPhoto = await _cameraController!.takePicture().timeout(
        const Duration(seconds: 2),
      );

      // Release camera lock early so manual shutter is not blocked by backend API latency
      _isCameraBusy = false;

      final CartItemModel? item = await _detectionService.detectItem(
        capturedPhoto,
      );

      if (item != null && mounted) {
        // Discard background scan if the photo was captured before the last user interaction/action
        if (_lastActionTime != null && captureTime.isBefore(_lastActionTime!)) {
          debugPrint(
            "[DashboardScreen] Discarding stale background scan result (captured before last action).",
          );
          return;
        }

        setState(() {
          _cachedDetectedItem = item;
          _cachedDetectionTime = DateTime.now();
        });
        debugPrint("[DashboardScreen] Pre-emptive scan detected: ${item.name}");
      }
    } catch (e) {
      _isCameraBusy = false;
      debugPrint("[DashboardScreen] Background scanning exception: $e");
    } finally {
      if (capturedPhoto != null && !kIsWeb) {
        try {
          final file = File(capturedPhoto.path);
          if (await file.exists()) {
            await file.delete();
            debugPrint(
              "[DashboardScreen] Cleaned up background temporary file: ${capturedPhoto.path}",
            );
          }
        } catch (e) {
          debugPrint(
            "[DashboardScreen] Failed to delete temp background file: $e",
          );
        }
      }
    }
  }

  Future<T?> _showBlurredDialog<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) async {
    WebBlurHelper.setBlurActive(true);
    try {
      return await showGeneralDialog<T>(
        context: context,
        barrierDismissible: barrierDismissible,
        barrierLabel: 'Dismiss Dialog',
        barrierColor: Colors.black.withValues(alpha: 0.25),
        transitionDuration: const Duration(milliseconds: 350),
        pageBuilder: (ctx, anim1, anim2) => builder(ctx),
        transitionBuilder: (ctx, anim1, anim2, child) {
          final curve = CurvedAnimation(
            parent: anim1,
            curve: Curves.easeOutCubic,
          );
          return AnimatedBuilder(
            animation: curve,
            builder: (context, childWidget) {
              final sigma = curve.value * 6.0;
              return BackdropFilter(
                filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: FadeTransition(
                  opacity: curve,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.92, end: 1.0).animate(curve),
                    child: childWidget,
                  ),
                ),
              );
            },
            child: child,
          );
        },
      );
    } finally {
      WebBlurHelper.setBlurActive(false);
    }
  }

  Future<void> _checkoutCart() async {
    if (_cartService.isEmpty || _isCheckingOut) return;

    setState(() => _isCheckingOut = true);

    final theme = Theme.of(context);

    // Trigger Missing Regulars Agent before checkout
    try {
      final currentCart = _cartService.items.map((item) {
        return {"sku": item.id, "name": item.name, "quantity": item.quantity};
      }).toList();

      final result = await ChatAgentService().analyzeCart(currentCart);
      final List<dynamic> missingItems = result['missing_regulars'] ?? [];

      if (missingItems.isNotEmpty && mounted) {
        bool proceedToCheckout = false;
        await DashboardSheets.showMissingRegularsSheet(
          context,
          missingItems: missingItems,
          onContinueToCheckout: () {
            proceedToCheckout = true;
          },
        );

        if (!proceedToCheckout || !mounted) {
          setState(() => _isCheckingOut = false);
          return;
        }
      }
    } catch (e) {
      debugPrint('[DashboardScreen] Missing Regulars analysis failed: $e');
      // Proceed silently if it fails
    }

    if (!mounted) return;

    final double total = _cartService.totalPrice;

    // Show confirmation dialog
    final bool? confirmed = await _showBlurredDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        backgroundColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                ),
                child: Icon(
                  Icons.shopping_bag_outlined,
                  color: theme.colorScheme.primary,
                  size: 30,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Confirm Checkout',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'You are about to checkout ${_cartService.itemCount} item${_cartService.itemCount == 1 ? '' : 's'} for a total of',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '₹${total.toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        side: const BorderSide(color: Color(0xFFD2E4E6)),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(
                          color: Color(0xFF4A5568),
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      child: const Text(
                        'Confirm',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    // Show Fulfillment Location & Time Selection Popup
    final FulfillmentSelection? fulfillmentSelection =
        await DashboardSheets.showFulfillmentSheet(
      context,
      amount: total,
    );

    if (fulfillmentSelection == null || !mounted) {
      setState(() => _isCheckingOut = false);
      return;
    }

    setState(() => _isCheckingOut = true);

    // Open the premium payment sheet
    await DashboardSheets.showPaymentSheet(
      context,
      amount: total,
      onPaymentSuccess: () async {
        final orderId =
            'H${DateTime.now().millisecondsSinceEpoch.toString().substring(4)}';
        await _cartService.checkout();
        if (mounted) {
          setState(() => _isCheckingOut = false);
          // Show order tracking & pickup confirmation screen
          DashboardSheets.showOrderConfirmationScreen(
            context,
            fulfillment: fulfillmentSelection,
            amount: total,
            orderId: orderId,
          );
        }
      },
    );

    // Reset checking out state if they cancel or close the sheet
    if (mounted) {
      setState(() => _isCheckingOut = false);
    }
  }

  bool _isCacheValid() {
    if (_cachedDetectedItem == null || _cachedDetectionTime == null) {
      return false;
    }
    final age = DateTime.now().difference(_cachedDetectionTime!);
    return age < const Duration(seconds: 3);
  }

  Future<void> _takePictureAndSearch() async {
    if (_isSearchingImage) return;

    if (_isCacheValid()) {
      debugPrint(
        "[DashboardScreen] Using valid pre-emptive scan cache for instant confirm sheet.",
      );
      final item = _cachedDetectedItem!;

      // Clear the cache after consuming it to prevent double actions
      setState(() {
        _cachedDetectedItem = null;
        _cachedDetectionTime = null;
        _isConfirmSheetOpen = true;
      });

      final CartItemModel? confirmedItem =
          await DashboardSheets.showItemConfirmSheet(context, item: item);

      if (mounted) {
        setState(() {
          _isConfirmSheetOpen = false;
          _lastActionTime = DateTime.now();
          _backgroundScanPauseUntil = DateTime.now().add(
            const Duration(milliseconds: 1200),
          );
          _cachedDetectedItem = null;
          _cachedDetectionTime = null;
        });
        if (confirmedItem != null) {
          _cartService.addItem(confirmedItem);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.fixed,
              content: Text('${confirmedItem.name} added to cart!'),
              backgroundColor: Theme.of(context).colorScheme.primary,
              duration: const Duration(milliseconds: 1500),
            ),
          );
        }
      }
      return;
    }

    // Yield up to 500ms if the camera is busy with a background scan capture
    int retryCount = 0;
    while (_isCameraBusy && retryCount < 10) {
      await Future.delayed(const Duration(milliseconds: 50));
      retryCount++;
    }

    if (!mounted) return;

    if (_isSearchingImage || _isCameraBusy) {
      debugPrint(
        "[DashboardScreen] Shutter click dropped: camera remains busy.",
      );
      return;
    }

    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.fixed,
          content: const Text('Camera is unavailable or not ready.'),
          backgroundColor: Theme.of(context).colorScheme.primary,
          duration: const Duration(milliseconds: 1500),
        ),
      );
      return;
    }

    setState(() {
      _isSearchingImage = true;
      _lastActionTime = DateTime.now();
      _backgroundScanPauseUntil = DateTime.now().add(
        const Duration(milliseconds: 1200),
      );
    });
    _isCameraBusy = true;

    XFile? capturedPhoto;
    try {
      capturedPhoto = await _cameraController!.takePicture().timeout(
        const Duration(seconds: 2),
      );
      _isCameraBusy = false; // Release lock early once capture succeeds

      final CartItemModel? item = await _detectionService.detectItem(
        capturedPhoto,
      );

      if (item != null && mounted) {
        // Show confirmation sheet — CLIP can confuse similar-looking products
        // (e.g. different Lays flavours). User verifies before cart is updated.
        setState(() => _isConfirmSheetOpen = true);
        final CartItemModel? confirmedItem =
            await DashboardSheets.showItemConfirmSheet(context, item: item);
        if (mounted) {
          setState(() {
            _isConfirmSheetOpen = false;
            _lastActionTime = DateTime.now();
            _backgroundScanPauseUntil = DateTime.now().add(
              const Duration(milliseconds: 1200),
            );
            _cachedDetectedItem = null;
            _cachedDetectionTime = null;
          });
        }
        if (confirmedItem != null && mounted) {
          _cartService.addItem(confirmedItem);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.fixed,
              content: Text('${confirmedItem.name} added to cart!'),
              backgroundColor: Theme.of(context).colorScheme.primary,
              duration: const Duration(milliseconds: 1500),
            ),
          );
        }
      } else if (mounted) {
        // Distance exceeded threshold — no confident match found
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.fixed,
            content: const Text(
              'Item not recognized. Try a closer scan.',
              style: TextStyle(color: Colors.white),
            ),
            backgroundColor: Theme.of(context).colorScheme.primary,
            duration: const Duration(milliseconds: 1500),
          ),
        );
      }
    } catch (e) {
      debugPrint("Error taking picture or searching: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.fixed,
            content: Text(
              'Error searching item',
              style: TextStyle(color: Colors.white),
            ),
            backgroundColor: Color(0xFFEF4444),
            duration: Duration(milliseconds: 1500),
          ),
        );
      }
    } finally {
      _isCameraBusy = false;
      if (capturedPhoto != null && !kIsWeb) {
        try {
          final file = File(capturedPhoto.path);
          if (await file.exists()) {
            await file.delete();
            debugPrint(
              "[DashboardScreen] Cleaned up temporary photo file: ${capturedPhoto.path}",
            );
          }
        } catch (e) {
          debugPrint("[DashboardScreen] Failed to delete temp photo file: $e");
        }
      }
      if (mounted) setState(() => _isSearchingImage = false);
    }
  }

  Future<String> _checkBackendStatus() async {
    final primary = dotenv.env['PRIMARY_DETECTION_URL']?.trim() ?? '';
    final backup = dotenv.env['BACKUP_DETECTION_URL']?.trim() ?? '';

    if (primary.isEmpty && backup.isEmpty) {
      return "Not Configured";
    }

    List<String> activeBackends = [];

    // Clean and check primary
    if (primary.isNotEmpty) {
      final cleanPrimary = primary
          .replaceAll(RegExp(r'/health$'), '')
          .replaceAll(RegExp(r'/$'), '');
      try {
        final response = await http
            .get(Uri.parse('$cleanPrimary/health'))
            .timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) {
          activeBackends.add("Oracle (Active)");
        }
      } catch (_) {
        // Silent fail for primary
      }
    }

    // Clean and check backup
    if (backup.isNotEmpty) {
      final cleanBackup = backup
          .replaceAll(RegExp(r'/health$'), '')
          .replaceAll(RegExp(r'/$'), '');
      try {
        final response = await http
            .get(Uri.parse('$cleanBackup/health'))
            .timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) {
          activeBackends.add("HF Space (Active)");
        }
      } catch (_) {
        // Silent fail for backup
      }
    }

    if (activeBackends.isNotEmpty) {
      return activeBackends.join(", ");
    } else {
      return "Disconnected (All Offline)";
    }
  }

  /// Silent background check — updates the indicator, no snackbar.
  Future<void> _refreshDbStatus() async {
    final results = await Future.wait([
      _chromaClient.checkConnectivity(),
      InventoryService().checkConnectivity(),
      _checkBackendStatus(),
    ]);
    final chromaStatus = results[0];
    final supabaseStatus = results[1];
    final backendStatus = results[2];

    if (!mounted) return;
    final allOk =
        chromaStatus.startsWith('Connected') &&
        supabaseStatus.startsWith('Connected') &&
        !backendStatus.startsWith('Disconnected');
    setState(
      () => _dbStatus = allOk
          ? DbConnectionStatus.live
          : DbConnectionStatus.error,
    );
  }

  Future<void> _checkDbStatus() async {
    // Show a loading snackbar while checking
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.fixed,
        content: const Text(
          'Checking database and backend connections...',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Theme.of(context).colorScheme.primary,
        duration: const Duration(milliseconds: 800),
      ),
    );

    final results = await Future.wait([
      _chromaClient.checkConnectivity(),
      InventoryService().checkConnectivity(),
      _checkBackendStatus(),
    ]);
    final chromaStatus = results[0];
    final supabaseStatus = results[1];
    final backendStatus = results[2];

    if (mounted) {
      final isChromaOk = chromaStatus.startsWith("Connected");
      final isSupabaseOk = supabaseStatus.startsWith("Connected");
      final isBackendOk = !backendStatus.startsWith("Disconnected");

      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.fixed,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ChromaDB: $chromaStatus',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Supabase: $supabaseStatus',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Backend: $backendStatus',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          backgroundColor: (isChromaOk && isSupabaseOk && isBackendOk)
              ? Theme.of(context).colorScheme.primary
              : const Color(0xFFEF4444),
          duration: const Duration(milliseconds: 1500),
        ),
      );
      // Also update only the DB indicator
      setState(
        () => _dbStatus = (isChromaOk && isSupabaseOk && isBackendOk)
            ? DbConnectionStatus.live
            : DbConnectionStatus.error,
      );
    }
  }

  void _incrementQuantity(int index) => _cartService.incrementQuantity(index);

  void _decrementQuantity(int index) => _cartService.decrementQuantity(index);

  void _removeItem(int index) => _cartService.removeItem(index);

  @override
  Widget build(BuildContext context) {
    final email = Supabase.instance.client.auth.currentUser?.email ?? 'Guest';
    final userInitial = email.isNotEmpty ? email[0].toUpperCase() : 'U';
    final theme = Theme.of(context);

    return Scaffold(
      appBar: DashboardAppBar(
        userInitial: userInitial,
        profilePicBase64: _profilePicBase64,
        dbStatus: _dbStatus,
        onProfileTap: _showProfileSheet,
        onDbStatusTap: _checkDbStatus,
        onNotificationsTap: _showNotificationsSheet,
        hasNotifications: _hasNotifications,
      ),
      body: Stack(
        clipBehavior: Clip.none,
        children: [
          // Background soft gradient
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    theme.scaffoldBackgroundColor,
                    Color.lerp(
                          theme.scaffoldBackgroundColor,
                          Colors.white,
                          0.5,
                        ) ??
                        Colors.white,
                    theme.scaffoldBackgroundColor,
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
          ),
          // Colorful glowing gradient bubbles (Orbs)
          Positioned(
            top: -150,
            right: -150,
            child: Container(
              width: 500,
              height: 500,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    theme.colorScheme.primary.withValues(alpha: 0.08),
                    theme.colorScheme.primary.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -50,
            left: -200,
            child: Container(
              width: 600,
              height: 600,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    theme.colorScheme.secondary.withValues(alpha: 0.15),
                    theme.colorScheme.secondary.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          // AnimatedBuilder isolates redraws to only the camera+cart layout
          // on each animation frame instead of rebuilding the entire screen.
          AnimatedBuilder(
            animation: _cartExpandController,
            builder: (context, _) => Column(
              children: [
                CameraViewport(
                  cameraController: _cameraController,
                  isCameraInitialized: _isCameraInitialized,
                  isSearchingImage: _isSearchingImage,
                  progress: _cartExpandController.value,
                  hasDetectedProduct: _isCacheValid(),
                ),
                Expanded(child: _buildShoppingZone()),
              ],
            ),
          ),
          // Bottom nav bar: pass as static child so it is NOT rebuilt on each frame.
          AnimatedBuilder(
            animation: _cartExpandController,
            builder: (context, child) {
              final progress = _cartExpandController.value;
              return Positioned(
                bottom: 20 - (120 * progress),
                left: 16,
                right: 16,
                child: Opacity(
                  opacity: (1.0 - progress).clamp(0.0, 1.0),
                  child: IgnorePointer(ignoring: progress > 0.5, child: child!),
                ),
              );
            },
            child: BottomNavBar(
              onChatTap: () async {
                _isDashboardActive = false;
                _stopBackgroundScanning();

                // Pre-emptively pause camera preview to prevent rendering load during transition
                if (_cameraController != null &&
                    _cameraController!.value.isInitialized) {
                  try {
                    await _cameraController!.pausePreview();
                    debugPrint(
                      "[DashboardScreen] Pre-emptively paused camera preview for Chat transition.",
                    );
                  } catch (e) {
                    debugPrint("Error pausing camera: $e");
                  }
                }

                if (!context.mounted) return;

                final route = PageRouteBuilder(
                  pageBuilder: (_, animation, __) => const ChatbotScreen(),
                  transitionsBuilder:
                      (_, animation, secondaryAnimation, child) {
                        final slideAnimation =
                            Tween<Offset>(
                              begin: const Offset(-1.0, 0.0),
                              end: Offset.zero,
                            ).animate(
                              CurvedAnimation(
                                parent: animation,
                                curve: Curves.fastOutSlowIn,
                                reverseCurve: Curves.fastOutSlowIn.flipped,
                              ),
                            );

                        return SlideTransition(
                          position: slideAnimation,
                          child: Material(
                            elevation: 16,
                            shadowColor: Colors.black38,
                            child: child,
                          ),
                        );
                      },
                  transitionDuration: const Duration(milliseconds: 300),
                  reverseTransitionDuration: const Duration(milliseconds: 250),
                );

                final pushFuture = Navigator.push(context, route);

                await pushFuture;

                _isDashboardActive = true;
                if (_cameraController == null ||
                    !_cameraController!.value.isInitialized) {
                  await _initializeCamera();
                } else {
                  try {
                    await _cameraController!.resumePreview();
                    debugPrint(
                      "[DashboardScreen] Resumed camera preview after Chat pop.",
                    );
                  } catch (e) {
                    debugPrint("Error resuming camera: $e");
                  }
                }
                _startBackgroundScanning();
              },
              onStoreTap: () async {
                _isDashboardActive = false;
                _stopBackgroundScanning();

                // Pre-emptively pause camera preview
                if (_cameraController != null &&
                    _cameraController!.value.isInitialized) {
                  try {
                    await _cameraController!.pausePreview();
                  } catch (e) {
                    debugPrint("Error pausing camera: $e");
                  }
                }

                if (!context.mounted) return;

                final route = PageRouteBuilder(
                  pageBuilder: (_, animation, __) => const InventoryScreen(),
                  transitionsBuilder:
                      (_, animation, secondaryAnimation, child) {
                        final slideAnimation =
                            Tween<Offset>(
                              begin: const Offset(1.0, 0.0),
                              end: Offset.zero,
                            ).animate(
                              CurvedAnimation(
                                parent: animation,
                                curve: Curves.fastOutSlowIn,
                                reverseCurve: Curves.fastOutSlowIn.flipped,
                              ),
                            );

                        return SlideTransition(
                          position: slideAnimation,
                          child: Material(
                            elevation: 16,
                            shadowColor: Colors.black38,
                            child: child,
                          ),
                        );
                      },
                  transitionDuration: const Duration(milliseconds: 300),
                  reverseTransitionDuration: const Duration(milliseconds: 250),
                );

                await Navigator.push(context, route);

                _isDashboardActive = true;
                if (_cameraController == null ||
                    !_cameraController!.value.isInitialized) {
                  await _initializeCamera();
                } else {
                  try {
                    await _cameraController!.resumePreview();
                  } catch (e) {
                    debugPrint("Error resuming camera: $e");
                  }
                }
                _startBackgroundScanning();
              },
              isSearchingImage: _isSearchingImage,
              onShutterTap: _takePictureAndSearch,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShoppingZone() {
    return ListenableBuilder(
      listenable: _cartService,
      builder: (context, child) {
        final theme = Theme.of(context);
        return Container(
          margin: const EdgeInsets.only(top: 16),
          decoration: const BoxDecoration(
            color: Color(0xFFFFFFFF),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(32),
              topRight: Radius.circular(32),
            ),
            border: Border(
              top: BorderSide(color: Color(0xFFD2E4E6), width: 1.5),
            ),
            boxShadow: [
              BoxShadow(
                color: Color(0x14001A23),
                blurRadius: 24,
                offset: Offset(0, -8),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag Handle & Header GestureDetector
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragUpdate: (details) {
                  final cameraViewportHeight =
                      MediaQuery.of(context).size.height * 0.33;
                  if (cameraViewportHeight > 0) {
                    _cartExpandController.value =
                        (_cartExpandController.value -
                                (details.primaryDelta ?? 0) /
                                    cameraViewportHeight)
                            .clamp(0.0, 1.0);
                  }
                },
                onVerticalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity < -300) {
                    _cartExpandController.animateTo(
                      1.0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                    );
                  } else if (velocity > 300) {
                    _cartExpandController.animateTo(
                      0.0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                    );
                  } else if (_cartExpandController.value > 0.5) {
                    _cartExpandController.animateTo(
                      1.0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                    );
                  } else {
                    _cartExpandController.animateTo(
                      0.0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                    );
                  }
                },
                onTap: () {
                  if (_cartExpandController.value > 0.5) {
                    _cartExpandController.animateTo(
                      0.0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                    );
                  } else {
                    _cartExpandController.animateTo(
                      1.0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                    );
                  }
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Small Drag Handle
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD2E4E6),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'My Cart',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.secondary.withValues(
                                    alpha: 0.3,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${_cartService.itemCount} ${_cartService.itemCount == 1 ? 'Item' : 'Items'}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: theme.colorScheme.primary,
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
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_cartService.isEmpty) ...[
                                const SizedBox(height: 40),
                                Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 72,
                                        height: 72,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: theme.colorScheme.primary
                                              .withValues(alpha: 0.05),
                                        ),
                                        child: Icon(
                                          Icons.shopping_cart_outlined,
                                          color: theme.colorScheme.primary,
                                          size: 32,
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        'Your cart is empty',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: theme.colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      const Text(
                                        'Scan an item to add it to your cart',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Color(0xFF4A5568),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 40),
                              ] else ...[
                                RepaintBoundary(
                                  child: ListView.builder(
                                    shrinkWrap: true,
                                    physics:
                                        const NeverScrollableScrollPhysics(),
                                    itemCount: _cartService.items.length,
                                    itemBuilder: (context, index) {
                                      final item = _cartService.items[index];
                                      return Dismissible(
                                        key: Key(item.id),
                                        direction: DismissDirection.endToStart,
                                        background: Container(
                                          margin: const EdgeInsets.only(
                                            bottom: 12,
                                          ),
                                          alignment: Alignment.centerRight,
                                          padding: const EdgeInsets.only(
                                            right: 20,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFEF4444),
                                            borderRadius: BorderRadius.circular(
                                              18,
                                            ),
                                          ),
                                          child: const Icon(
                                            Icons.delete_outline,
                                            color: Colors.white,
                                            size: 24,
                                          ),
                                        ),
                                        onDismissed: (_) => _removeItem(index),
                                        child: () {
                                          final slug = InventoryService()
                                              .getSlugByName(item.name);
                                          final displayImageUrl =
                                              (item.imageUrl.startsWith(
                                                    'http',
                                                  ) &&
                                                  !item.imageUrl.contains(
                                                    'string',
                                                  ))
                                              ? item.imageUrl
                                              : (slug != null
                                                    ? InventoryService()
                                                          .getImageUrl(slug)
                                                    : item.imageUrl);
                                          
                                          final localProduct = slug != null ? InventoryService().getProductFromLocal(slug) : null;
                                          final List<dynamic>? pricesRaw = item.prices ?? (localProduct != null ? localProduct['prices'] : null);
                                          final List<double> itemPrices = pricesRaw != null
                                              ? pricesRaw.map((e) => (e as num).toDouble()).toList()
                                              : [];
                                          if (itemPrices.isNotEmpty && !itemPrices.contains(item.price)) {
                                            itemPrices.insert(0, item.price);
                                          }

                                          return CartItem(
                                            imageUrl: displayImageUrl,
                                            name: item.name,
                                            details:
                                                "${item.quantity} ${item.quantity == 1 ? 'Item' : 'Items'} • ₹${(item.price * item.quantity).toStringAsFixed(2)}",
                                            quantity: item.quantity,
                                            onIncrement: () =>
                                                _incrementQuantity(index),
                                            onDecrement: () =>
                                                _decrementQuantity(index),
                                            onRemove: () => _removeItem(index),
                                            prices: itemPrices.isNotEmpty ? itemPrices : null,
                                            selectedPrice: item.price,
                                            onPriceChanged: (newPrice) {
                                              _cartService.updateItemPrice(index, newPrice);
                                            },
                                          );
                                        }(),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      // ── Checkout Bar ──────────────────────────────────────
                      if (!_cartService.isEmpty)
                        AnimatedBuilder(
                          animation: _cartExpandController,
                          builder: (context, child) => Padding(
                            padding: EdgeInsets.fromLTRB(
                              0,
                              8,
                              0,
                              120 - (100 * _cartExpandController.value),
                            ),
                            child: child!,
                          ),
                          child: CheckoutBar(
                            totalPrice: _cartService.totalPrice,
                            isCheckingOut: _isCheckingOut,
                            onCheckout: _checkoutCart,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showProfileSheet() {
    final user = Supabase.instance.client.auth.currentUser;
    final name = user?.userMetadata?['name'] as String? ?? 'User';
    final email = user?.email ?? 'Guest';

    _isDashboardActive = false;
    _stopBackgroundScanning();

    // Pre-emptively pause camera preview to prevent rendering load during transition
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      try {
        _cameraController!.pausePreview().catchError((e) {
          debugPrint("Error pausing camera for Profile transition: $e");
        });
        debugPrint(
          "[DashboardScreen] Pre-emptively paused camera preview for Profile transition.",
        );
      } catch (e) {
        debugPrint("Error pausing camera: $e");
      }
    }

    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, animation, __) => ProfilePage(
          name: name,
          email: email,
          onLogout: () async {
            await Supabase.instance.client.auth.signOut();
            if (mounted) {
              Navigator.of(context).popUntil((route) => route.isFirst);
            }
          },
        ),
        transitionsBuilder: (_, animation, secondaryAnimation, child) {
          final slideAnimation =
              Tween<Offset>(
                begin: const Offset(-1.0, 0.0),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(
                  parent: animation,
                  curve: Curves.fastOutSlowIn,
                  reverseCurve: Curves.fastOutSlowIn.flipped,
                ),
              );
          return SlideTransition(
            position: slideAnimation,
            child: Material(
              elevation: 16,
              shadowColor: Colors.black38,
              child: child,
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 250),
      ),
    ).then((_) async {
      _isDashboardActive = true;
      if (_cameraController == null ||
          !_cameraController!.value.isInitialized) {
        await _initializeCamera();
      } else {
        try {
          await _cameraController!.resumePreview();
          debugPrint(
            "[DashboardScreen] Resumed camera preview after Profile pop.",
          );
        } catch (e) {
          debugPrint("Error resuming camera: $e");
        }
      }
      _startBackgroundScanning();
      _loadProfilePic();
    });
  }

  Future<void> _checkNotificationsStatus() async {
    final list = await NotificationStorageService.getNotifications();
    if (mounted) {
      setState(() {
        _hasNotifications = list.any(
          (item) => !(item['read'] as bool? ?? false),
        );
      });
    }
  }

  void _showNotificationsSheet() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, animation, __) => const NotificationsPage(),
        transitionsBuilder: (_, animation, __, child) {
          return SlideTransition(
            position:
                Tween<Offset>(
                  begin: const Offset(1.0, 0.0), // Slides in from right to left
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeInOut),
                ),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    ).then((_) => _checkNotificationsStatus());
  }
}
