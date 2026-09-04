import { dashCaseToCamelCase } from '../../../../../../../../misc/case-converters/dash-case';
import { ILinesOrNull } from '../../../../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../../primary/primary-transpilers.type';
import { IBindProperty } from '../../extract-bind-property-from-reactive-html-attribute';

/**
 * Syntax:
 *  - standard: $[name]
 *  - prefixed: bind-input-name
 */

export interface ITranspileReactiveHTMLReactiveInputToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  bindProperty: IBindProperty;
}

export function transpileReactiveHTMLReactiveInputToJSLines(
  {
    bindProperty,
    transpilers,
  }: ITranspileReactiveHTMLReactiveInputToJSLinesOptions,
): ILinesOrNull {
  if (bindProperty.inputMode) {
    const {
      transpileSetReactiveInputToJSLines,
    } = transpilers;

    const name: string = dashCaseToCamelCase(bindProperty.name);

    return [
      `// reactive input '${name}'`,
      ...transpileSetReactiveInputToJSLines({
        node: ['node'],
        name: [JSON.stringify(name)],
        value: bindProperty.value,
      }),
    ];
  } else {
    return null;
  }
}

