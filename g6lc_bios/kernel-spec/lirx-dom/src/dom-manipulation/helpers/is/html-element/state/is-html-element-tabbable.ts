import { isFocusableHTMLElementTabbable } from './is-focusable-html-element-tabbable';
import { isHTMLElementFocusable } from './is-html-element-focusable';

/**
 * From: https://stackoverflow.com/questions/7208161/focus-next-element-in-tab-index
 */
export function isHTMLElementTabbable(
  element: HTMLElement,
): boolean {
  return isHTMLElementFocusable(element)
    && isFocusableHTMLElementTabbable(element);
}
