import 'package:flutter/material.dart';
import '../../../services/cart_service.dart';
import '../../../services/inventory_service.dart';
import '../../../services/chat_agent_service.dart';
import '../../../models/fulfillment_option.dart';
import '../../dashboard/widgets/cart_item.dart';
import '../../dashboard/widgets/checkout_bar.dart';
import '../../dashboard/widgets/dashboard_sheets.dart';

class ChatCartSheet extends StatefulWidget {
  const ChatCartSheet({super.key});

  @override
  State<ChatCartSheet> createState() => _ChatCartSheetState();
}

class _ChatCartSheetState extends State<ChatCartSheet> {
  bool _isCheckingOut = false;
  final CartService _cartService = CartService();

  Future<void> _checkoutCart() async {
    if (_cartService.isEmpty || _isCheckingOut) return;

    setState(() => _isCheckingOut = true);

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
      debugPrint('[ChatCartSheet] Missing Regulars analysis failed: $e');
      // Proceed silently if it fails
    }

    if (!mounted) return;

    final double total = _cartService.totalPrice;

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

    bool paymentSuccess = false;
    final orderId =
        'H${DateTime.now().millisecondsSinceEpoch.toString().substring(4)}';

    // Open the premium payment sheet
    await DashboardSheets.showPaymentSheet(
      context,
      amount: total,
      onPaymentSuccess: () async {
        paymentSuccess = true;
        await _cartService.checkout();
      },
    );

    if (mounted) {
      setState(() => _isCheckingOut = false);
      if (paymentSuccess) {
        // Pop the ChatCartSheet
        Navigator.of(context).pop();

        // Show order tracking screen
        DashboardSheets.showOrderConfirmationScreen(
          context,
          fulfillment: fulfillmentSelection,
          amount: total,
          orderId: orderId,
        );
      }
    }
  }

  void _incrementQuantity(int index) => _cartService.incrementQuantity(index);
  void _decrementQuantity(int index) => _cartService.decrementQuantity(index);
  void _removeItem(int index) => _cartService.removeItem(index);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final maxHeight = mediaQuery.size.height * 0.75;

    return ListenableBuilder(
      listenable: _cartService,
      builder: (context, child) {
        return Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom + 20),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [
              BoxShadow(
                color: Color(0x14001A23),
                blurRadius: 24,
                offset: Offset(0, -8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag Handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD2E4E6),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Title Header
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
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
              ),
              const SizedBox(height: 12),

              // Cart Items / Empty State
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
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
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: 0.05,
                                  ),
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
                                'Ask the assistant to add items to your cart',
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
                        ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _cartService.items.length,
                          itemBuilder: (context, index) {
                            final item = _cartService.items[index];
                            return Dismissible(
                              key: Key(item.id),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                margin: const EdgeInsets.only(bottom: 12),
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 20),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEF4444),
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.white,
                                  size: 24,
                                ),
                              ),
                              onDismissed: (_) => _removeItem(index),
                              child: () {
                                final slug = InventoryService().getSlugByName(
                                  item.name,
                                );
                                final displayImageUrl =
                                    (item.imageUrl.startsWith('http') &&
                                        !item.imageUrl.contains('string'))
                                    ? item.imageUrl
                                    : (slug != null
                                          ? InventoryService().getImageUrl(slug)
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
                                   onIncrement: () => _incrementQuantity(index),
                                   onDecrement: () => _decrementQuantity(index),
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
                      ],
                    ],
                  ),
                ),
              ),

              // Checkout Bar
              if (!_cartService.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: CheckoutBar(
                    totalPrice: _cartService.totalPrice,
                    isCheckingOut: _isCheckingOut,
                    onCheckout: _checkoutCart,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
