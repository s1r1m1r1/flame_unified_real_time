// import 'package:flame/rendering.dart';

// /// Extension on [Decorator] to provide additional functionality for chain management
// /// and synchronized state updates.
// extension DecoratorExtension on Decorator {
//   /// Returns the next decorator in the chain.
//   ///
//   /// This relies on the `next` getter added to the base [Decorator] class.
//   Decorator? get nextDecorator => next;

//   /// Iterates through the chain and returns the first decorator of type [T].
//   T? find<T extends Decorator>() {
//     Decorator? current = this;
//     while (current != null) {
//       if (current is T) {
//         return current;
//       }
//       current = current.next;
//     }
//     return null;
//   }

//   /// Checks if a decorator of type [T] exists in the chain.
//   bool hasType<T extends Decorator>() => find<T>() != null;

//   /// Safely updates the decorator if it's not null.
//   ///
//   /// Note: The base [Decorator.update] already handles chain propagation.
//   void updateChain(double dt) {
//     update(dt);
//   }
// }

// /// Extension on nullable [Decorator] for safe chain updates.
// extension NullableDecoratorExtension on Decorator? {
//   /// Safely updates the decorator chain if the head is not null.
//   void updateSafe(double dt) {
//     this?.update(dt);
//   }
// }
