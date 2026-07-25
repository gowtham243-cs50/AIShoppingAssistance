import 'package:flutter/material.dart';
import '../../../models/fulfillment_option.dart';

class FulfillmentSheet extends StatefulWidget {
  final double amount;
  final ValueChanged<FulfillmentSelection>? onConfirmed;

  const FulfillmentSheet({
    super.key,
    required this.amount,
    this.onConfirmed,
  });

  @override
  State<FulfillmentSheet> createState() => _FulfillmentSheetState();
}

class _FulfillmentSheetState extends State<FulfillmentSheet> {
  FulfillmentType _selectedType = FulfillmentType.counterPickup;

  // Counter options
  final List<FulfillmentLocationOption> _counterOptions = const [
    FulfillmentLocationOption(
      id: 'counter_a',
      title: 'Counter A - Express Checkout',
      subtitle: 'Ground Floor, Main Entrance Mall Hall',
      estimatedTime: 'Ready in 10 Mins',
      iconName: 'storefront',
    ),
    FulfillmentLocationOption(
      id: 'counter_b',
      title: 'Counter B - Fresh Produce & Bakery',
      subtitle: '1st Floor, Section B3',
      estimatedTime: 'Ready in 15 Mins',
      iconName: 'shopping_bag',
    ),
    FulfillmentLocationOption(
      id: 'counter_c',
      title: 'Counter C - Customer Service Desk',
      subtitle: '2nd Floor, Central Plaza',
      estimatedTime: 'Ready in 12 Mins',
      iconName: 'support_agent',
    ),
  ];

  // Parking options
  final List<FulfillmentLocationOption> _parkingOptions = const [
    FulfillmentLocationOption(
      id: 'parking_bay_4',
      title: 'Parking Bay 4 - East Gate',
      subtitle: 'Level P1, Near Pillar E4',
      estimatedTime: 'Ready in 15 Mins',
      iconName: 'directions_car',
    ),
    FulfillmentLocationOption(
      id: 'parking_bay_12',
      title: 'Parking Bay 12 - West Gate',
      subtitle: 'Level P2, Near Elevator Hub',
      estimatedTime: 'Ready in 18 Mins',
      iconName: 'local_parking',
    ),
    FulfillmentLocationOption(
      id: 'drive_thru',
      title: 'Drive-Thru Express Pickup Lane',
      subtitle: 'Ground Level, Outer Perimeter Road',
      estimatedTime: 'Ready in 12 Mins',
      iconName: 'time_to_leave',
    ),
  ];

  late String _selectedCounterId;
  late String _selectedParkingId;

  final TextEditingController _vehicleController = TextEditingController(
    text: 'White Swift • KA 05 AB 1234',
  );
  final TextEditingController _addressController = TextEditingController(
    text: '472 Jersey Ave, Apt 4B, Jersey City, NJ 07302',
  );

  @override
  void initState() {
    super.initState();
    _selectedCounterId = _counterOptions[0].id;
    _selectedParkingId = _parkingOptions[0].id;
  }

  @override
  void dispose() {
    _vehicleController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  FulfillmentSelection _buildSelection() {
    if (_selectedType == FulfillmentType.counterPickup) {
      final option = _counterOptions.firstWhere(
        (o) => o.id == _selectedCounterId,
        orElse: () => _counterOptions[0],
      );
      return FulfillmentSelection(
        type: FulfillmentType.counterPickup,
        title: option.title,
        subtitle: option.subtitle,
        estimatedTime: option.estimatedTime,
      );
    } else if (_selectedType == FulfillmentType.parkingPickup) {
      final option = _parkingOptions.firstWhere(
        (o) => o.id == _selectedParkingId,
        orElse: () => _parkingOptions[0],
      );
      return FulfillmentSelection(
        type: FulfillmentType.parkingPickup,
        title: option.title,
        subtitle: option.subtitle,
        estimatedTime: option.estimatedTime,
        vehicleOrAddressDetail: _vehicleController.text.trim(),
      );
    } else {
      return FulfillmentSelection(
        type: FulfillmentType.homeDelivery,
        title: 'Home Doorstep Express Delivery',
        subtitle: _addressController.text.trim(),
        estimatedTime: 'Delivered in 35 - 45 Mins',
        vehicleOrAddressDetail: _addressController.text.trim(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final maxHeight = mediaQuery.size.height * 0.85;

    return Padding(
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
          boxShadow: [
            BoxShadow(
              color: Color(0x1E001A23),
              blurRadius: 28,
              offset: Offset(0, -10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle Bar
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header Title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Select Pickup / Delivery',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Choose where & when to collect your groceries',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF64748B)),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Fulfillment Option Type Selectors (Tabs)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    _buildTypeTab(
                      type: FulfillmentType.counterPickup,
                      label: 'Counter',
                      icon: Icons.storefront_rounded,
                      timeBadge: '10 min',
                    ),
                    _buildTypeTab(
                      type: FulfillmentType.parkingPickup,
                      label: 'Parking',
                      icon: Icons.directions_car_rounded,
                      timeBadge: '15 min',
                    ),
                    _buildTypeTab(
                      type: FulfillmentType.homeDelivery,
                      label: 'Delivery',
                      icon: Icons.local_shipping_rounded,
                      timeBadge: '35 min',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Scrollable Content
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_selectedType == FulfillmentType.counterPickup)
                      _buildCounterSection(theme),
                    if (_selectedType == FulfillmentType.parkingPickup)
                      _buildParkingSection(theme),
                    if (_selectedType == FulfillmentType.homeDelivery)
                      _buildDeliverySection(theme),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),

            // Bottom Action Bar
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Total Payable',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        '₹${widget.amount.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        final selection = _buildSelection();
                        if (widget.onConfirmed != null) {
                          widget.onConfirmed!(selection);
                        } else {
                          Navigator.pop(context, selection);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        elevation: 4,
                        shadowColor: theme.colorScheme.primary.withValues(
                          alpha: 0.4,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'Proceed to Payment',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(width: 8),
                          Icon(Icons.arrow_forward_rounded, size: 18),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeTab({
    required FulfillmentType type,
    required String label,
    required IconData icon,
    required String timeBadge,
  }) {
    final theme = Theme.of(context);
    final isSelected = _selectedType == type;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _selectedType = type;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: isSelected
                        ? theme.colorScheme.primary
                        : const Color(0xFF64748B),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.w600,
                      color: isSelected
                          ? theme.colorScheme.primary
                          : const Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected
                      ? theme.colorScheme.primary.withValues(alpha: 0.1)
                      : const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  timeBadge,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isSelected
                        ? theme.colorScheme.primary
                        : const Color(0xFF64748B),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCounterSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Select In-Store Pickup Counter',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Color(0xFF334155),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFA7F3D0)),
              ),
              child: const Text(
                '⚡ Fast Counter Express',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF059669),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ..._counterOptions.map((opt) {
          final isSelected = opt.id == _selectedCounterId;
          return _buildLocationCard(
            option: opt,
            isSelected: isSelected,
            onTap: () => setState(() => _selectedCounterId = opt.id),
            theme: theme,
          );
        }),
      ],
    );
  }

  Widget _buildParkingSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Select Curbside / Parking Bay',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Color(0xFF334155),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFBFDBFE)),
              ),
              child: const Text(
                '🚗 Car Delivery to Bay',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2563EB),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ..._parkingOptions.map((opt) {
          final isSelected = opt.id == _selectedParkingId;
          return _buildLocationCard(
            option: opt,
            isSelected: isSelected,
            onTap: () => setState(() => _selectedParkingId = opt.id),
            theme: theme,
          );
        }),
        const SizedBox(height: 16),
        const Text(
          'Vehicle Info for Parking Pickup',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Color(0xFF334155),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _vehicleController,
          decoration: InputDecoration(
            hintText: 'e.g. Model, Color & License Plate Number',
            prefixIcon: const Icon(Icons.time_to_leave_outlined, size: 20),
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: theme.colorScheme.primary,
                width: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDeliverySection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                theme.colorScheme.primary.withValues(alpha: 0.06),
                const Color(0xFFEEF2FF),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.15),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.local_shipping_rounded,
                  color: theme.colorScheme.primary,
                  size: 26,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Receive at Your Doorstep',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Estimated delivery: 35 - 45 mins',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF059669),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Delivery Address',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Color(0xFF334155),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _addressController,
          maxLines: 2,
          decoration: InputDecoration(
            hintText: 'Enter complete street address...',
            prefixIcon: const Padding(
              padding: EdgeInsets.only(bottom: 24),
              child: Icon(Icons.location_on_outlined, size: 20),
            ),
            filled: true,
            fillColor: const Color(0xFFF8FAFC),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: theme.colorScheme.primary,
                width: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLocationCard({
    required FulfillmentLocationOption option,
    required bool isSelected,
    required VoidCallback onTap,
    required ThemeData theme,
  }) {
    IconData getIcon(String iconName) {
      switch (iconName) {
        case 'storefront':
          return Icons.storefront_rounded;
        case 'shopping_bag':
          return Icons.shopping_bag_outlined;
        case 'support_agent':
          return Icons.support_agent_rounded;
        case 'directions_car':
          return Icons.directions_car_rounded;
        case 'local_parking':
          return Icons.local_parking_rounded;
        case 'time_to_leave':
          return Icons.time_to_leave_rounded;
        default:
          return Icons.place_rounded;
      }
    }

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha: 0.04)
              : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : const Color(0xFFE2E8F0),
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: isSelected
                    ? theme.colorScheme.primary
                    : const Color(0xFFF1F5F9),
                shape: BoxShape.circle,
              ),
              child: Icon(
                getIcon(option.iconName),
                color: isSelected ? Colors.white : const Color(0xFF64748B),
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: isSelected
                          ? theme.colorScheme.primary
                          : const Color(0xFF1E293B),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    option.subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isSelected
                    ? theme.colorScheme.primary.withValues(alpha: 0.1)
                    : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                option.estimatedTime,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isSelected
                      ? theme.colorScheme.primary
                      : const Color(0xFF475569),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
