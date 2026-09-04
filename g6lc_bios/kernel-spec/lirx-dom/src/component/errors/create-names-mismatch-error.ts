export function createNamesMismatchError(
  expected: string,
  found?: string,
): Error {
  return new Error(`Names mismatch. Expected '${expected}'${(found === void 0) ? '' : ` found '${found}'`}`);
}
