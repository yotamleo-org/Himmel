/**
 * Applies projectLineOrder to the keyed parts. Unkeyed parts keep their slots, a key's
 * parts stay together, and keys missing from `order` follow in their original order.
 */
export function orderParts(parts, order) {
    const slots = [];
    const byKey = new Map();
    parts.forEach((part, index) => {
        if (part.key === null)
            return;
        slots.push(index);
        byKey.set(part.key, [...(byKey.get(part.key) ?? []), part.text]);
    });
    const reordered = [];
    for (const key of order) {
        reordered.push(...(byKey.get(key) ?? []));
        byKey.delete(key);
    }
    for (const texts of byKey.values())
        reordered.push(...texts);
    const result = parts.map((part) => part.text);
    slots.forEach((slot, index) => {
        result[slot] = reordered[index];
    });
    return result;
}
//# sourceMappingURL=order.js.map