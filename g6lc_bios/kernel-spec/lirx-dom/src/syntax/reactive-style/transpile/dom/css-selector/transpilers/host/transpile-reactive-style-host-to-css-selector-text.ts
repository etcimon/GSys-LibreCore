import { extractParenthesisContent } from '../../../../functions/extract-parenthesis-content';
import { IHavingHostSelectorOptions } from '../../../../types/having-host-selector-options';

const HOST_SELECTOR = ':host';

export interface ITranspileReactiveStyleHostToCSSSelectorTextOptions extends IHavingHostSelectorOptions {
  readonly selector: string;
}

export function transpileReactiveStyleHostToCSSSelectorText(
  {
    selector,
    hostSelector,
  }: ITranspileReactiveStyleHostToCSSSelectorTextOptions,
): string {
  let newSelector: string = '';
  let position: number = 0;

  while (position < selector.length) {
    const index: number = selector.indexOf(HOST_SELECTOR, position);
    if (index === -1) {
      newSelector += selector.slice(position);
      position = selector.length;
    } else {
      const selectorBefore: string = selector.slice(position, index);
      let selectorHostSelf: string;

      position = index + HOST_SELECTOR.length;

      if (selector.startsWith('(', position)) {
        const i: number = extractParenthesisContent(selector, position);
        selectorHostSelf = selector.slice(position + 1, i - 1);
        position = i;
      } else {
        selectorHostSelf = '';
      }

      newSelector += `${selectorBefore}${hostSelector}${selectorHostSelf}`;
    }
  }

  return newSelector;
}
