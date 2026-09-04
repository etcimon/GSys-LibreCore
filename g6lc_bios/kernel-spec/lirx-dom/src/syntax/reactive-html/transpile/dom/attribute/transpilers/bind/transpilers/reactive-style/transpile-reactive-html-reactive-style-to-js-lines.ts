import { ILinesOrNull } from '../../../../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../../primary/primary-transpilers.type';
import { IBindProperty } from '../../extract-bind-property-from-reactive-html-attribute';
import { generateJSLinesForReactiveStyle } from './generate-js-lines-for-reactive-style';
import { generateJSLinesForReactiveStylePropertiesMap } from './generate-js-lines-for-reactive-style-properties-map';

const REACTIVE_STYLE_STANDARD_REGEXP: RegExp = new RegExp('^style\\.(.*)$');
const REACTIVE_STYLE_PREFIXED_REGEXP: RegExp = new RegExp('^style-(.*)');

/**
 * Syntax:
 *  - standard:
 *    [style.font-size]="'12px'"
 *    [style...]="{ color: 'blue' }"
 *
 *  - prefixed:
 *    bind-style-font-size="'12px'"
 *    bind-style---="{ color: 'blue' }"
 */

export interface ITranspileReactiveHTMLReactiveStyleToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly bindProperty: IBindProperty;
}

export function transpileReactiveHTMLReactiveStyleToJSLines(
  {
    bindProperty,
    ...options
  }: ITranspileReactiveHTMLReactiveStyleToJSLinesOptions,
): ILinesOrNull {
  const match: RegExpExecArray | null = bindProperty.prefixMode
    ? REACTIVE_STYLE_PREFIXED_REGEXP.exec(bindProperty.name)
    : REACTIVE_STYLE_STANDARD_REGEXP.exec(bindProperty.name);

  if (match === null) {
    return null;
  } else {
    let styleName: string = match[1];

    if (bindProperty.prefixMode && (styleName === '--')) {
      styleName = '..';
    }

    return (styleName === '..')
      ? generateJSLinesForReactiveStylePropertiesMap({
        ...options,
        value: bindProperty.value,
      })
      : generateJSLinesForReactiveStyle({
        ...options,
        name: styleName,
        value: bindProperty.value,
      });
  }
}

