import { uuid } from '../../../misc/uuid';
import { isDocumentFragmentNode } from '../is/node-type/is-document-fragment-node';
import { isElementNode } from '../is/node-type/is-element-node';

// https://github.com/whatwg/dom/issues/1081

export interface IElementMatchesOptions {
  readonly scope?: Node;
}

/**
 * Returns true if "element" matches "selector".
 * This is similar to element.matches(selector), however, it supports an optional property "scope".
 * If "scope" is specified and the selector contains ":scope",
 * then ":scope" will refer to the property scope instead of the element itself.
 */
export function elementMatches(
  element: Element,
  selector: string,
  {
    scope,
  }: IElementMatchesOptions = {},
): boolean {
  if (scope === void 0) {
    return element.matches(selector);
  } else {
    const hasScope: boolean = selector.includes(':scope');

    if (hasScope) {
      if (isElementNode(scope)) {
        const id: string = generatePatchQuerySelectorScopeId();
        scope.setAttribute(id, '');
        const matches: boolean = element.matches(selector.replace(':scope', `[${id}]`));
        scope.removeAttribute(id);
        return matches;
      } else if (isDocumentFragmentNode(scope)) {
        const id: string = generatePatchQuerySelectorScopeId();
        const _parentNode: Element = document.createElement('div');
        _parentNode.setAttribute(id, '');
        _parentNode.appendChild(scope);

        const matches: boolean = element.matches(selector.replace(':scope', `[${id}]`));

        while (_parentNode.firstChild !== null) {
          scope.appendChild(_parentNode.firstChild);
        }

        return matches;
      } else {
        return element.matches(selector);
      }
    } else {
      return element.matches(selector);
    }
  }
}

/*--*/

function generatePatchQuerySelectorScopeId(): string {
  return `scope-${uuid()}`;
}
