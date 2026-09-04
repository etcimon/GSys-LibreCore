/**
 * Every word starts with an uppercase.
 */
export function isPascalCase(
  input: string,
): boolean {
  return (/^[a-zA-Z]*$/g).test(input);
}

/**
 * INFO: Assumes input is pascal case
 */
export function pascalCaseToDashCase(
  input: string,
): string {
  return input.replace(/[A-Z]/g, (match: string, index: number) => `${(index === 0) ? '' : '-'}${match[0].toLowerCase()}`);
}

