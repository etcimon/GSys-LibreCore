import { isHTMLInputElement } from '../is/html-element/is-html-input-element';

export function focusHTMLElement(
  element: HTMLElement,
  options?: FocusOptions,
): boolean {
  element.focus(options);
  if (isHTMLInputElement(element)) {
    element.select();
  }
  return document.activeElement === element;
}
