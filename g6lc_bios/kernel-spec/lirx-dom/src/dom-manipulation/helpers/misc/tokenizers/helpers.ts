export function wrap(pattern: string): string {
  return '(?:' + pattern + ')';
}

export function startEnd(pattern: string): string {
  return '^' + pattern + '$';
}
