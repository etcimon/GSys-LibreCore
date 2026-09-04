import { IHavingHostSelectorOptions } from '../../types/having-host-selector-options';
import {
  transpileReactiveStyleHostContextToCSSSelectorText,
} from './transpilers/host-context/transpile-reactive-style-host-context-to-css-selector-text';
import { transpileReactiveStyleHostToCSSSelectorText } from './transpilers/host/transpile-reactive-style-host-to-css-selector-text';

export interface ITranspileReactiveStyleCSSSelectorToCSSSelectorOptions extends IHavingHostSelectorOptions {
  readonly selector: string;
}

export function transpileReactiveStyleCSSSelectorToCSSSelector(
  {
    selector,
    ...options
  }: ITranspileReactiveStyleCSSSelectorToCSSSelectorOptions,
): string {
  const transpilers = [
    transpileReactiveStyleHostContextToCSSSelectorText,
    transpileReactiveStyleHostToCSSSelectorText,
  ];

  return transpilers.reduce(
    (
      selector: string,
      transpiler: (options: ITranspileReactiveStyleCSSSelectorToCSSSelectorOptions) => string,
    ): string => {
      return transpiler({
        ...options,
        selector,
      });
    },
    selector,
  );
}
