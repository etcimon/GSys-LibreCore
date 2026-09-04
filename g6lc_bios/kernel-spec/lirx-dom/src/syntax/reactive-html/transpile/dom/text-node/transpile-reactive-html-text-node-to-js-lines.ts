import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { IHavingPrimaryTranspilersOptions } from '../../primary/primary-transpilers.type';
import {
  transpileReactiveHTMLReactiveTextNodeToJSLines,
} from './transpilers/reactive-text/transpile-reactive-html-reactive-text-node-to-js-lines';
import {
  transpileReactiveHTMLStaticTextNodeToJSLines,
} from './transpilers/static-text/transpile-reactive-html-static-text-node-to-js-lines';

export interface ITranspileReactiveHTMLTextNodeToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Text;
}

export const transpileReactiveHTMLTextNodeToJSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveHTMLTextNodeToJSLinesOptions]>(() => [
  transpileReactiveHTMLReactiveTextNodeToJSLines,
  transpileReactiveHTMLStaticTextNodeToJSLines,
]);

