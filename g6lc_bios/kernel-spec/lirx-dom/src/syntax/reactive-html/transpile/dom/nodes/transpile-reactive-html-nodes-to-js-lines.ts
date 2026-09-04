import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { IHavingPrimaryTranspilersOptions } from '../../primary/primary-transpilers.type';
import { transpileReactiveHTMLGenericNodesToJSLines } from './transpilers/transpile-reactive-html-generic-nodes-to-js-lines';

export interface ITranspileReactiveHTMLNodesToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly nodes: ArrayLike<Node>;
}

export const transpileReactiveHTMLNodesToJSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveHTMLNodesToJSLinesOptions]>(() => [
  transpileReactiveHTMLGenericNodesToJSLines,
]);


