import { dashCaseToCamelCase } from '../../../../../../../../misc/case-converters/dash-case';
import { ILines } from '../../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../../primary/primary-transpilers.type';
import { IBindProperty } from '../../extract-bind-property-from-reactive-html-attribute';

/**
 * Syntax:
 *  - standard: [property]
 *  - prefixed: bind-property
 */

export interface ITranspileReactiveHTMLReactivePropertyToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  bindProperty: IBindProperty;
}

export function transpileReactiveHTMLReactivePropertyToJSLines(
  {
    bindProperty,
    transpilers,
  }: ITranspileReactiveHTMLReactivePropertyToJSLinesOptions,
): ILines {
  const {
    transpileSetReactivePropertyToJSLines,
  } = transpilers;

  const name: string = dashCaseToCamelCase(bindProperty.name);

  return [
    `// reactive property '${name}'`,
    ...transpileSetReactivePropertyToJSLines({
      node: ['node'],
      name: [JSON.stringify(name)],
      value: bindProperty.value,
    }),
  ];
}

