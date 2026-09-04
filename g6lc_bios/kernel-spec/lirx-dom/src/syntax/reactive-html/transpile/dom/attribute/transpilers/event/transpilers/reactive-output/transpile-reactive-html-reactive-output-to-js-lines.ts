import { dashCaseToCamelCase } from '../../../../../../../../misc/case-converters/dash-case';
import { ILinesOrNull } from '../../../../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../../primary/primary-transpilers.type';
import { IEventProperty } from '../../extract-event-property-from-reactive-html-attribute';

/**
 * Syntax:
 *  - standard: ($output)
 *  - prefixed: on-$output
 */

export interface ITranspileReactiveHTMLReactiveOutputToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly eventProperty: IEventProperty;
}

export function transpileReactiveHTMLReactiveOutputToJSLines(
  {
    eventProperty,
    transpilers,
  }: ITranspileReactiveHTMLReactiveOutputToJSLinesOptions,
): ILinesOrNull {
  if (eventProperty.outputMode) {
    const {
      transpileSetReactiveOutputToJSLines,
    } = transpilers;

    const name: string = dashCaseToCamelCase(eventProperty.name);

    return [
      `// reactive output '${name}'`,
      ...transpileSetReactiveOutputToJSLines({
        node: ['node'],
        name: [JSON.stringify(name)],
        value: [eventProperty.value],
        observableMode: eventProperty.observableMode,
      }),
    ];
  } else {
    return null;
  }
}

