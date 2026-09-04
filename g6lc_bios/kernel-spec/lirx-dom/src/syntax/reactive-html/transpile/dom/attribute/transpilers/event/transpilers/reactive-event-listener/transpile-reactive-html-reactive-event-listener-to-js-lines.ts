import { ILines } from '../../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../../primary/primary-transpilers.type';
import { IEventProperty } from '../../extract-event-property-from-reactive-html-attribute';

/**
 * Syntax:
 *  - standard: (event)
 *  - prefixed: on-event
 */

export interface ITranspileReactiveHTMLReactiveEventListenerToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly eventProperty: IEventProperty;
}

export function transpileReactiveHTMLReactiveEventListenerToJSLines(
  {
    eventProperty,
    transpilers,
  }: ITranspileReactiveHTMLReactiveEventListenerToJSLinesOptions,
): ILines {
  const {
    transpileSetReactiveEventListenerToJSLines,
  } = transpilers;

  const name: string = eventProperty.name;

  return [
    `// reactive event listener '${name}'`,
    ...transpileSetReactiveEventListenerToJSLines({
      node: ['node'],
      name: [JSON.stringify(name)],
      value: [eventProperty.value],
      observableMode: eventProperty.observableMode,
    }),
  ];
}

