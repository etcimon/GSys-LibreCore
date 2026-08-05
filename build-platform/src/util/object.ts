// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// object.ts — Small, dependency-free object helpers.

/** True for plain objects (not arrays, not null, not class instances/dates). */
export function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== "object") return false;
  if (Array.isArray(value)) return false;
  const proto = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
}

/**
 * Deep-merge `override` onto `base`, returning a new object.
 *
 * Rules tuned for config resolution:
 *  - Plain objects merge recursively.
 *  - Arrays and scalars from `override` REPLACE the base value wholesale
 *    (so a user array like `extensions` fully controls the result).
 *  - `undefined` values in `override` are ignored (keep the base value).
 */
export function deepMerge<T>(base: T, override: unknown): T {
  if (override === undefined) return base;
  if (!isPlainObject(base) || !isPlainObject(override)) {
    return override as T;
  }
  const out: Record<string, unknown> = { ...base };
  for (const [key, value] of Object.entries(override)) {
    if (value === undefined) continue;
    const baseValue = (base as Record<string, unknown>)[key];
    out[key] = isPlainObject(baseValue) && isPlainObject(value)
      ? deepMerge(baseValue, value)
      : value;
  }
  return out as T;
}
