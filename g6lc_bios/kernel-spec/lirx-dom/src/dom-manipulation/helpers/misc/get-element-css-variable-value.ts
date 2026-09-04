export function getElementCSSVariableValue(
  node: HTMLElement,
  variableName: string,
): string {
  return getComputedStyle(node).getPropertyValue(variableName);
}

export function getElementCSSVariableValueOrDefault(
  node: HTMLElement,
  variableName: string,
  defaultValue: string,
): string {
  const value: string = getElementCSSVariableValue(node, variableName);
  return (value === '')
    ? defaultValue
    : value;
}
