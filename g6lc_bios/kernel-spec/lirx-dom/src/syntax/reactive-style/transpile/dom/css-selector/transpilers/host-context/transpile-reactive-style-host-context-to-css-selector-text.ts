import { extractParenthesisContent } from '../../../../functions/extract-parenthesis-content';
import { IHavingHostSelectorOptions } from '../../../../types/having-host-selector-options';

const HOST_CONTEXT_SELECTOR = ':host-context';

export interface ITranspileReactiveStyleHostContextToCSSSelectorTextOptions extends IHavingHostSelectorOptions {
  readonly selector: string;
}

export function transpileReactiveStyleHostContextToCSSSelectorText(
  {
    selector,
    hostSelector,
  }: ITranspileReactiveStyleHostContextToCSSSelectorTextOptions,
): string {
  // https://blog.angular-university.io/angular-host-context/
  // https://developer.mozilla.org/en-US/docs/Web/CSS/:host-context()

  let newSelector: string = '';
  let position: number = 0;

  while (position < selector.length) {
    const index: number = selector.indexOf(HOST_CONTEXT_SELECTOR, position);

    if (index === -1) {
      newSelector += selector.slice(position);
      position = selector.length;
    } else {
      const selectorBefore: string = selector.slice(position, index);
      let selectorGenericCSSStyleRule: string;

      position = index + HOST_CONTEXT_SELECTOR.length;

      if (selector.startsWith('(', position)) {
        const i: number = extractParenthesisContent(selector, position);
        selectorGenericCSSStyleRule = `${selector.slice(position + 1, i - 1)} `;
        position = i;
      } else {
        selectorGenericCSSStyleRule = '';
      }

      newSelector += `${selectorBefore}${selectorGenericCSSStyleRule}${hostSelector}`;
    }
  }

  return newSelector;
}
