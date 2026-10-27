"""Wilson score interval for a binomial proportion, rounded to four decimals unless digits=None."""
import math


def wilson(k, n, z=1.959964, digits=4):
    if not n:
        return None
    p = k / n
    den = 1 + z * z / n
    mid = (p + z * z / (2 * n)) / den
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    lo, hi = max(0.0, mid - half), min(1.0, mid + half)
    if digits is None:
        return {"lo": lo, "hi": hi}
    return {"lo": round(lo, digits), "hi": round(hi, digits)}
