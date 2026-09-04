import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import { extractEventPropertyFromReactiveHTMLAttribute, IEventProperty } from './extract-event-property-from-reactive-html-attribute';
import {
  transpileReactiveHTMLReactiveEventListenerToJSLines,
} from './transpilers/reactive-event-listener/transpile-reactive-html-reactive-event-listener-to-js-lines';
import {
  transpileReactiveHTMLReactiveOutputToJSLines,
} from './transpilers/reactive-output/transpile-reactive-html-reactive-output-to-js-lines';

export interface ITranspileReactiveHTMLEventPropertyToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly eventProperty: IEventProperty;
}

export const transpileReactiveHTMLEventPropertyToJSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveHTMLEventPropertyToJSLinesOptions]>(() => [
  transpileReactiveHTMLReactiveOutputToJSLines,
  transpileReactiveHTMLReactiveEventListenerToJSLines,
]);

/*--------------------*/

export interface ITranspileReactiveHTMLEventPropertyAttributeToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly attribute: Attr;
}

export const transpileReactiveHTMLEventPropertyAttributeToJSLines = (
  {
    attribute,
    ...options
  }: ITranspileReactiveHTMLEventPropertyAttributeToJSLinesOptions,
): ILinesOrNull => {
  const eventProperty: IEventProperty | null = extractEventPropertyFromReactiveHTMLAttribute(attribute);
  return (eventProperty === null)
    ? null
    : transpileReactiveHTMLEventPropertyToJSLines({
      ...options,
      eventProperty,
    });
};
