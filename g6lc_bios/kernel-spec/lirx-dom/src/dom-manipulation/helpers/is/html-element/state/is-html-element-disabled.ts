export function isHTMLElementDisabled(
  element: HTMLElement,
): boolean {
  return element.matches(':disabled');
}
