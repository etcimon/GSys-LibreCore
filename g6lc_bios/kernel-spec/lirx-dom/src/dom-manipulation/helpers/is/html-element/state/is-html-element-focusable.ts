import { isHTMLElementVisible } from './is-html-element-visible';
import { isVisibleHTMLElementFocusable } from './is-visible-html-element-focusable';

export function isHTMLElementFocusable(
  element: HTMLElement,
): boolean {
  return isVisibleHTMLElementFocusable(element)
    && isHTMLElementVisible(element);
}
