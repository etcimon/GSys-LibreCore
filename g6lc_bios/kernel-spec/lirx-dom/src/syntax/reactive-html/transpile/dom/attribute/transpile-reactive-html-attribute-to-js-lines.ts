import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { IHavingPrimaryTranspilersOptions } from '../../primary/primary-transpilers.type';
import {
  transpileReactiveHTMLBindPropertyAttributeToJSLines,
} from './transpilers/bind/transpile-reactive-html-bind-property-attribute-to-js-lines';
import {
  transpileReactiveHTMLEventPropertyAttributeToJSLines,
} from './transpilers/event/transpile-reactive-html-event-property-attribute-to-js-lines';
import { transpileReactiveHTMLStaticAttributeToJSLines } from './transpilers/static/transpile-reactive-html-static-attribute-to-js-lines';

export interface ITranspileReactiveHTMLAttributeToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly attribute: Attr;
}

export const transpileReactiveHTMLAttributeToJSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveHTMLAttributeToJSLinesOptions]>(() => [
  transpileReactiveHTMLBindPropertyAttributeToJSLines,
  transpileReactiveHTMLEventPropertyAttributeToJSLines,
  // transpileReactiveHTMLModifierAttributeToReactiveDOMJSLines,
  transpileReactiveHTMLStaticAttributeToJSLines,
]);

