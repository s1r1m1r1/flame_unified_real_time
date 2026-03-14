import 'package:flame/components.dart';
import 'package:flame_unified_real_time/flame_unified_real_time.dart';

/// A [SpriteComponent] that delegates its rendering to a [UnifiedSpriteBatchComponent].
/// This allows static sprites to be batched and sorted globally along with animations.
class UnifiedBatchSpriteComponent extends SpriteComponent
    with UnifiedBatchChildMixin {
  UnifiedBatchSpriteComponent({
    super.sprite,
    super.paint,
    super.position,
    super.size,
    super.scale,
    super.angle,
    super.nativeAngle,
    super.anchor,
    super.children,
    super.priority,
    super.key,
  });
}
