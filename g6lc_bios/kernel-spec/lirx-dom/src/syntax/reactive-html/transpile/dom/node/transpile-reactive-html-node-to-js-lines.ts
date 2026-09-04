import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { IHavingPrimaryTranspilersOptions } from '../../primary/primary-transpilers.type';
import { transpileReactiveHTMLGenericNodeToJSLines } from './transpilers/transpile-reactive-html-generic-node-to-js-lines';

export interface ITranspileReactiveHTMLNodeToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Node;
}

export const transpileReactiveHTMLNodeToJSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveHTMLNodeToJSLinesOptions]>(() => [
  transpileReactiveHTMLGenericNodeToJSLines,
]);




