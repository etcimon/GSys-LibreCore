/**
 * Every word starts with an uppercase except for the first one.
 */
export function isCamelCase(
  input: string,
): boolean {
  return (/^[a-z][a-zA-Z]*$/g).test(input);
}

/**
 * INFO: Assumes input is camel case
 */
export function camelCaseToDashCase(
  input: string,
): string {
  return input.replace(/[A-Z]/g, (match: string) => `-${match.toLowerCase()}`);
}

