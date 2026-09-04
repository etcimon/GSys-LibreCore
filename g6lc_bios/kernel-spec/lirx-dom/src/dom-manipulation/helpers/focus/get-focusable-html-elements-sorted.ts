import { focusableHTMLElementsIterable } from './focusable-html-elements-iterable';
import { sortFocusableHTMLElements } from './sort-focusable-html-elements';

export function getFocusableHTMLElementsSorted(
  parentElement: HTMLElement,
  reverse?: boolean,
): HTMLElement[] {
  return sortFocusableHTMLElements(
    Array.from(
      focusableHTMLElementsIterable(parentElement),
    ),
    reverse,
  );
}
