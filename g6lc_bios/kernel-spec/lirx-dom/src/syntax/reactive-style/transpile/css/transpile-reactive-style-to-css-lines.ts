import { ILinesOrNull } from '../../../misc/lines/lines-or-null.type';
import { transpileReactiveStyleStyleElementToCSSLines } from '../dom/style-element/transpile-reactive-style-style-element-to-js-lines';
import { IHavingHostSelectorOptions } from '../types/having-host-selector-options';

export interface ITranspileReactiveStyleToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly css: string;
}

export function transpileReactiveStyleToCSSLines(
  {
    css,
    ...options
  }: ITranspileReactiveStyleToCSSLinesOptions,
): ILinesOrNull {

  // return  css.replace(/:host/g, hostSelector);

  const node: HTMLStyleElement = document.createElement('style');
  node.textContent = css;

  return transpileReactiveStyleStyleElementToCSSLines({
    ...options,
    node,
  });
}


