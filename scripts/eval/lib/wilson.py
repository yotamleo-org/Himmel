"""Wilson score interval for a binomial proportion, rounded to four decimals."""
import math


def wilson(k, n, z=1.959964):
    if not n:
        return None
    p = k / n
    den = 1 + z * z / n
    mid = (p + z * z / (2 * n)) / den
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return {"lo": round(max(0.0, mid - half), 4), "hi": round(min(1.0, mid + half), 4)}
