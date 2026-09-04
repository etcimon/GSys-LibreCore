import { isHTMLAnchorElement } from '../is-html-anchor-element';
import { isHTMLAreaElement } from '../is-html-area-element';
import { isHTMLButtonElement } from '../is-html-button-element';
import { isHTMLInputElement } from '../is-html-input-element';
import { isHTMLSelectElement } from '../is-html-select-element';
import { isHTMLTextareaElement } from '../is-html-textarea-element';
import { isHTMLElementDisabled } from './is-html-element-disabled';

/**
 * Returns true if an element is focusable.
 * @doc: https://developer.mozilla.org/en-US/docs/Web/HTML/Global_attributes/tabindex
 */
export function isVisibleHTMLElementFocusable(
  element: HTMLElement,
): boolean {
  if (
    element.hasAttribute('tabindex')
    || (element.tabIndex >= 0)
  ) {
    return true;
  } else {
    if (isHTMLInputElement(element)) {
      return (element.type !== 'hidden')
        && !isHTMLElementDisabled(element);
    } else if (
      isHTMLSelectElement(element)
      || isHTMLButtonElement(element)
      || isHTMLTextareaElement(element)
    ) {
      return !isHTMLElementDisabled(element);
    } else if (
      isHTMLAnchorElement(element)
      || isHTMLAreaElement(element)
    ) {
      return element.hasAttribute('href');
    } else {
      return element.hasAttribute('contenteditable');
    }
  }
}

