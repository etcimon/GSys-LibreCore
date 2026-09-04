/**
 * Returns true if a focusable element is tabbable.
 * It must have a non negative tabindex
 */
export function isFocusableHTMLElementTabbable(
  element: HTMLElement,
): boolean {
  return element.tabIndex >= 0;
}
