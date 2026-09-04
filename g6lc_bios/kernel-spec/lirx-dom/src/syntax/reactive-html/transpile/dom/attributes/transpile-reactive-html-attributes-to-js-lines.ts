import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { IHavingPrimaryTranspilersOptions } from '../../primary/primary-transpilers.type';
import { transpileReactiveHTMLGenericAttributesToJSLines } from './transpilers/transpile-reactive-html-generic-attributes-to-js-lines';

export interface ITranspileReactiveHTMLAttributesToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly attributes: ArrayLike<Attr>;
}

export const transpileReactiveHTMLAttributesToJSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveHTMLAttributesToJSLinesOptions]>(() => [
  transpileReactiveHTMLGenericAttributesToJSLines,
]);

