import type { FirstLineSegment } from '../config.js';
import type { Part } from './parts.js';
/**
 * Applies projectLineOrder to the keyed parts. Unkeyed parts keep their slots, a key's
 * parts stay together, and keys missing from `order` follow in their original order.
 */
export declare function orderParts(parts: Part[], order: readonly FirstLineSegment[]): string[];
//# sourceMappingURL=order.d.ts.map