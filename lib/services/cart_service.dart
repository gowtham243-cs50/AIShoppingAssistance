import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/cart_item_model.dart';

/// Singleton cart service that acts as the session-scoped cart database.
/// Persists cart state across page refreshes via SharedPreferences and syncs
/// with Supabase for logged-in users.
class CartService extends ChangeNotifier {
  static final CartService instance = CartService();
  static final CartService _instance = CartService._internal();
  factory CartService() => _instance;

  SupabaseClient? get _supabase {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  CartService._internal() {
    // Listen for auth state changes to load/clear user cart reactively
    try {
      _supabase?.auth.onAuthStateChange.listen((data) {
        final user = data.session?.user;
        if (user != null) {
          _loadActiveCartFromSupabase(user.id);
        } else {
          _items.clear();
          _persist();
          _loadedUserId = null;
          notifyListeners();
        }
      });
    } catch (e) {
      debugPrint('[CartService] Could not listen to auth state changes: $e');
    }
  }

  static const String _cartKey = 'cart_items_v1';

  final List<CartItemModel> _items = [];
  bool _isLoaded = false;
  Timer? _syncTimer;
  Future<void>? _activeLoadFuture;
  String? _loadedUserId;

  /// Cached Supabase row ID of the current active cart so we can UPDATE
  /// directly without a SELECT round-trip on every sync.
  String? _activeCartId;

  /// Hash of the last successfully synced cart state.
  /// Syncs are skipped when the cart has not changed since the last write.
  String? _lastSyncedHash;

  String _cartHash() => _items.map((e) => '${e.id}:${e.quantity}').join(',');

  void _scheduleSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(seconds: 2), () {
      _syncActiveCart();
    });
  }

  /// Read-only view of the cart contents.
  List<CartItemModel> get items => List.unmodifiable(_items);

  /// Total item count (sum of quantities).
  int get itemCount => _items.fold(0, (sum, item) => sum + item.quantity);

  /// Total price in Rupees (₹).
  double get totalPrice =>
      _items.fold(0.0, (sum, item) => sum + item.price * item.quantity);

  bool get isEmpty => _items.isEmpty;

  bool get isLoaded => _isLoaded;

  // ─────────────────────────── Persistence ───────────────────────────────────

  /// Loads cart from SharedPreferences. Call once during app init.
  Future<void> load() async {
    if (_isLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_cartKey);
      if (raw != null) {
        final List<dynamic> decoded = jsonDecode(raw);
        _items.clear();
        _items.addAll(decoded.map((e) => CartItemModel.fromJson(e)));
      }

      // If already logged in on startup, sync the latest active cart from Supabase
      final client = _supabase;
      final user = client?.auth.currentUser;
      if (user != null) {
        await _loadActiveCartFromSupabase(user.id);
      }
    } catch (e) {
      debugPrint('[CartService] load error: $e');
    } finally {
      _isLoaded = true;
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cartKey,
        jsonEncode(_items.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[CartService] persist error: $e');
    }
  }

  // ────────────────────────── Supabase Syncing ────────────────────────────────

  /// Restoration method to fetch active cart from Supabase on login or app start.
  Future<void> _loadActiveCartFromSupabase(String userId) async {
    if (_loadedUserId == userId) return;
    if (_activeLoadFuture != null) {
      await _activeLoadFuture;
      return;
    }

    final completer = Completer<void>();
    _activeLoadFuture = completer.future;

    try {
      final client = _supabase;
      if (client == null) return;
      final activeCart = await client
          .from('user_carts')
          .select('id, items')
          .eq('user_id', userId)
          .eq('status', 'active')
          .maybeSingle();

      if (activeCart != null && activeCart['items'] != null) {
        // Cache the row ID so future syncs skip the SELECT.
        _activeCartId = activeCart['id'] as String?;
        final List<dynamic> dbItems = activeCart['items'] as List<dynamic>;
        _items.clear();
        _items.addAll(
          dbItems.map((e) => CartItemModel.fromJson(e as Map<String, dynamic>)),
        );
        _persist();
        _lastSyncedHash = _cartHash();
        _loadedUserId = userId;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[CartService] Error loading active cart from Supabase: $e');
    } finally {
      _activeLoadFuture = null;
      completer.complete();
    }
  }

  /// Pushes changes to Supabase in the background whenever the cart is modified.
  /// Uses a cached cart ID to avoid an extra SELECT on every sync, and skips
  /// the write entirely when the cart contents have not changed.
  Future<void> _syncActiveCart() async {
    final client = _supabase;
    final user = client?.auth.currentUser;
    if (user == null || client == null) return;

    // Skip sync when nothing has changed since the last write.
    final currentHash = _cartHash();
    if (currentHash == _lastSyncedHash) return;

    try {
      if (_activeCartId != null) {
        // Fast path: we already know the row ID — skip the SELECT.
        await client
            .from('user_carts')
            .update({
              'items': _items.map((e) => e.toJson()).toList(),
              'total_price': totalPrice,
              'updated_at': DateTime.now().toIso8601String(),
            })
            .eq('id', _activeCartId!);
        _lastSyncedHash = currentHash;
      } else {
        // Slow path: fetch the row ID once and cache it for future syncs.
        final activeCart = await client
            .from('user_carts')
            .select('id')
            .eq('user_id', user.id)
            .eq('status', 'active')
            .maybeSingle();

        if (activeCart != null) {
          _activeCartId = activeCart['id'] as String?;
          await client
              .from('user_carts')
              .update({
                'items': _items.map((e) => e.toJson()).toList(),
                'total_price': totalPrice,
                'updated_at': DateTime.now().toIso8601String(),
              })
              .eq('id', _activeCartId!);
          _lastSyncedHash = currentHash;
        } else if (_items.isNotEmpty) {
          // No active cart row exists yet — create one.
          final inserted = await client
              .from('user_carts')
              .insert({
                'user_id': user.id,
                'items': _items.map((e) => e.toJson()).toList(),
                'total_price': totalPrice,
                'status': 'active',
              })
              .select('id')
              .maybeSingle();
          _activeCartId = inserted?['id'] as String?;
          _lastSyncedHash = currentHash;
        }
      }
    } catch (e) {
      debugPrint('[CartService] Supabase active cart sync error: $e');
    }
  }

  // ─────────────────────────── CRUD ──────────────────────────────────────────

  void removeItemBySkuOrName(String sku, String name) {
    final nameLower = name.toLowerCase();
    final index = _items.indexWhere(
      (e) =>
          e.id == sku ||
          (sku.isNotEmpty && e.details.contains(sku)) ||
          e.name.toLowerCase() == nameLower,
    );
    if (index != -1) {
      removeItem(index);
    }
  }

  void removeOrDecrementItemBySkuOrName(String sku, String name, int quantity) {
    final nameLower = name.toLowerCase();
    final index = _items.indexWhere(
      (e) =>
          e.id == sku ||
          (sku.isNotEmpty && e.details.contains(sku)) ||
          e.name.toLowerCase() == nameLower,
    );
    if (index != -1) {
      final currentQty = _items[index].quantity;
      if (currentQty > quantity) {
        for (int i = 0; i < quantity; i++) {
          decrementQuantity(index);
        }
      } else {
        removeItem(index);
      }
    }
  }

  /// Adds [item] to the cart. If an item with the same name already exists
  /// (case-insensitive), its quantity is incremented instead of adding a duplicate.
  void addItem(CartItemModel item) {
    final nameLower = item.name.toLowerCase();
    final existingIdx = _items.indexWhere(
      (e) => e.name.toLowerCase() == nameLower,
    );
    if (existingIdx != -1) {
      _items[existingIdx] = _items[existingIdx].copyWith(
        quantity: _items[existingIdx].quantity + item.quantity,
        price: item.price,
      );
    } else {
      _items.add(item);
    }
    _persist();
    _scheduleSync();
    notifyListeners();
  }

  void incrementQuantity(int index) {
    if (index < 0 || index >= _items.length) return;
    _items[index].quantity++;
    _persist();
    _scheduleSync();
    notifyListeners();
  }

  void decrementQuantity(int index) {
    if (index < 0 || index >= _items.length) return;
    if (_items[index].quantity > 1) {
      _items[index].quantity--;
      _persist();
      _scheduleSync();
    } else {
      removeItem(index);
    }
    notifyListeners();
  }

  void updateItemPrice(int index, double newPrice) {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    _items[index] = item.copyWith(price: newPrice);
    _persist();
    _scheduleSync();
    notifyListeners();
  }

  void removeItem(int index) {
    if (index < 0 || index >= _items.length) return;
    _items.removeAt(index);
    _persist();
    // If the cart becomes empty, delete the active cart from Supabase
    final client = _supabase;
    final user = client?.auth.currentUser;
    if (client != null && user != null && _items.isEmpty) {
      _syncTimer
          ?.cancel(); // Cancel any pending sync if we are deleting the cart
      final cartIdToDelete = _activeCartId;
      _activeCartId = null;
      _lastSyncedHash = null;
      if (cartIdToDelete != null) {
        client
            .from('user_carts')
            .delete()
            .eq('id', cartIdToDelete)
            .then(
              (_) => null,
              onError: (e) =>
                  debugPrint('[CartService] Error deleting active cart: $e'),
            );
      } else {
        client
            .from('user_carts')
            .delete()
            .eq('user_id', user.id)
            .eq('status', 'active')
            .then(
              (_) => null,
              onError: (e) =>
                  debugPrint('[CartService] Error deleting active cart: $e'),
            );
      }
    } else {
      _scheduleSync();
    }
    notifyListeners();
  }

  void clearCart() {
    _items.clear();
    _persist();
    final client = _supabase;
    final user = client?.auth.currentUser;
    if (client != null && user != null) {
      _syncTimer?.cancel();
      final cartIdToDelete = _activeCartId;
      _activeCartId = null;
      _lastSyncedHash = null;
      if (cartIdToDelete != null) {
        client
            .from('user_carts')
            .delete()
            .eq('id', cartIdToDelete)
            .then(
              (_) => null,
              onError: (e) =>
                  debugPrint('[CartService] Error deleting active cart: $e'),
            );
      } else {
        client
            .from('user_carts')
            .delete()
            .eq('user_id', user.id)
            .eq('status', 'active')
            .then(
              (_) => null,
              onError: (e) =>
                  debugPrint('[CartService] Error deleting active cart: $e'),
            );
      }
    }
    notifyListeners();
  }

  // ─────────────────────────── Checkout ──────────────────────────────────────

  /// Completes the checkout: marks the active cart as processed in Supabase,
  /// clears the in-memory cart, and wipes local storage.
  Future<void> checkout() async {
    final client = _supabase;
    final user = client?.auth.currentUser;
    if (client != null && user != null) {
      try {
        final activeCart = await client
            .from('user_carts')
            .select('id')
            .eq('user_id', user.id)
            .eq('status', 'active')
            .maybeSingle();

        if (activeCart != null) {
          // Progress state to 'processed'
          await client
              .from('user_carts')
              .update({
                'status': 'processed',
                'updated_at': DateTime.now().toIso8601String(),
              })
              .eq('id', activeCart['id']);
        } else if (_items.isNotEmpty) {
          // If no active cart exists in DB but we have local items, write direct processed entry
          await client.from('user_carts').insert({
            'user_id': user.id,
            'items': _items.map((e) => e.toJson()).toList(),
            'total_price': totalPrice,
            'status': 'processed',
          });
        }
      } catch (e) {
        debugPrint('[CartService] Supabase checkout sync error: $e');
      }
    }

    _items.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cartKey);
    } catch (e) {
      debugPrint('[CartService] checkout clear error: $e');
    }
    notifyListeners();
  }
}
