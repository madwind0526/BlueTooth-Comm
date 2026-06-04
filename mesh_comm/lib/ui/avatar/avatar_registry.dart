import 'package:flutter/material.dart';

class AvatarOption {
  final String key;
  final String label;
  final String assetPath;

  const AvatarOption({
    required this.key,
    required this.label,
    required this.assetPath,
  });
}

class AvatarRegistry {
  AvatarRegistry._();

  static const defaultKey = 'animal_monkey';

  static const options = [
    AvatarOption(
      key: 'animal_monkey',
      label: 'Monkey',
      assetPath: 'assets/avatars/animal-avartar-0.png',
    ),
    AvatarOption(
      key: 'animal_cat',
      label: 'Cat',
      assetPath: 'assets/avatars/animal-avartar-1.png',
    ),
    AvatarOption(
      key: 'animal_raccoon',
      label: 'Raccoon',
      assetPath: 'assets/avatars/animal-avartar-2.png',
    ),
    AvatarOption(
      key: 'animal_tiger',
      label: 'Tiger',
      assetPath: 'assets/avatars/animal-avartar-3.png',
    ),
    AvatarOption(
      key: 'animal_fox',
      label: 'Fox',
      assetPath: 'assets/avatars/animal-avartar-4.png',
    ),
    AvatarOption(
      key: 'animal_otter',
      label: 'Otter',
      assetPath: 'assets/avatars/animal-avartar-5.png',
    ),
    AvatarOption(
      key: 'animal_dog',
      label: 'Dog',
      assetPath: 'assets/avatars/animal-avartar-6.png',
    ),
    AvatarOption(
      key: 'animal_pig',
      label: 'Pig',
      assetPath: 'assets/avatars/animal-avartar-7.png',
    ),
    AvatarOption(
      key: 'animal_deer',
      label: 'Deer',
      assetPath: 'assets/avatars/animal-avartar-8.png',
    ),
    AvatarOption(
      key: 'animal_bear',
      label: 'Bear',
      assetPath: 'assets/avatars/animal-avartar-9.png',
    ),
    AvatarOption(
      key: 'animal_fox_cat',
      label: 'Fox cat',
      assetPath: 'assets/avatars/animal-avartar-A.png',
    ),
    AvatarOption(
      key: 'animal_panda',
      label: 'Panda',
      assetPath: 'assets/avatars/animal-avartar-B.png',
    ),
    AvatarOption(
      key: 'animal_zebra',
      label: 'Zebra',
      assetPath: 'assets/avatars/animal-avartar-C.png',
    ),
    AvatarOption(
      key: 'animal_donkey',
      label: 'Donkey',
      assetPath: 'assets/avatars/animal-avartar-D.png',
    ),
    AvatarOption(
      key: 'animal_elephant',
      label: 'Elephant',
      assetPath: 'assets/avatars/animal-avartar-E.png',
    ),
    AvatarOption(
      key: 'animal_rabbit',
      label: 'Rabbit',
      assetPath: 'assets/avatars/animal-avartar-F.png',
    ),
  ];

  static AvatarOption byKey(String? key) {
    return options.firstWhere(
      (option) => option.key == key,
      orElse: () => options.first,
    );
  }
}

class AvatarBadge extends StatelessWidget {
  final String? avatarKey;
  final double size;
  final IconData? fallbackIcon;
  final Color fallbackColor;

  const AvatarBadge({
    super.key,
    required this.avatarKey,
    this.size = 40,
    this.fallbackIcon,
    this.fallbackColor = Colors.white70,
  });

  @override
  Widget build(BuildContext context) {
    final option = AvatarRegistry.byKey(avatarKey);
    return ClipOval(
      child: Image.asset(
        option.assetPath,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return CircleAvatar(
            radius: size / 2,
            backgroundColor: const Color(0xFF2D2858),
            child: Icon(
              fallbackIcon ?? Icons.person,
              size: size * 0.55,
              color: fallbackColor,
            ),
          );
        },
      ),
    );
  }
}

class AvatarPickerGrid extends StatelessWidget {
  final String selectedKey;
  final ValueChanged<String> onSelected;

  const AvatarPickerGrid({
    super.key,
    required this.selectedKey,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: AvatarRegistry.options.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemBuilder: (context, index) {
        final option = AvatarRegistry.options[index];
        final selected = option.key == selectedKey;
        return Tooltip(
          message: option.label,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => onSelected(option.key),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Center(
                child: AvatarBadge(avatarKey: option.key, size: 46),
              ),
            ),
          ),
        );
      },
    );
  }
}
