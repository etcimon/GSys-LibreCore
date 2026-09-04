/**
 * Generates an unique id
 */
export function uuid(): string {
  return `${Math.floor(Math.random() * Number.MAX_SAFE_INTEGER).toString(16).padStart(14, '0')}-${Date.now().toString(16).padStart(12, '0')}`;
}

