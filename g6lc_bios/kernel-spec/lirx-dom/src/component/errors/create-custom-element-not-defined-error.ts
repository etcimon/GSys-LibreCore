export function createCustomElementNotDefinedError(
  name: string,
): Error {
  return new Error(`The custom element '${name}' is not defined`);
}
