import 'package:flame/components.dart';
import 'package:flame_unified_real_time/flame_unified_real_time.dart';

/// A [SpriteAnimationComponent] that delegates its rendering to a [UnifiedSpriteBatchComponent].
/// This allows animations to be batched and sorted globally along with other components.
class UnifiedBatchAnimationComponent extends SpriteAnimationComponent
    with UnifiedBatchChildMixin {
  UnifiedBatchAnimationComponent({
    super.animation,
    super.playing,
    super.removeOnFinish,
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

  @override
  void onMount() {
    super.onMount();
    // It should register itself if it has a batch parent in the hierarchy or game.
    // Usually, the creator will call [registerWithBatch] manually.
  }
}
