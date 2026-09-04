import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { IHavingPrimaryTranspilersOptions } from '../../primary/primary-transpilers.type';
import { transpileReactiveHTMLRXAsyncToJSLines } from './transpilers/rx-async/transpile-reactive-html-rx-async-to-js-lines';
import { transpileReactiveHTMLRXContainerToJSLines } from './transpilers/rx-container/transpile-reactive-html-rx-container-to-js-lines';
import { transpileReactiveHTMLRXForLoopToJSLines } from './transpilers/rx-for-loop/transpile-reactive-html-rx-for-loop-to-js-lines';
import { transpileReactiveHTMLRXIfToJSLines } from './transpilers/rx-if/transpile-reactive-html-rx-if-to-js-lines';
import { transpileReactiveHTMLRXInjectSlotToLines } from './transpilers/rx-inject-slot/transpile-reactive-html-rx-inject-slot-to-js-lines';
import {
  transpileReactiveHTMLRXInjectTemplateToLines,
} from './transpilers/rx-inject-template/transpile-reactive-html-rx-inject-template-to-js-lines';
import { transpileReactiveHTMLRXScriptToJSLines } from './transpilers/rx-script/transpile-reactive-html-rx-script-to-js-lines';
import { transpileReactiveHTMLRXSwitchToJSLines } from './transpilers/rx-switch/transpile-reactive-html-rx-switch-to-js-lines';
import { transpileReactiveHTMLRXTemplateToJSLines } from './transpilers/rx-template/transpile-reactive-html-rx-template-to-js-lines';
import { transpileReactiveHTMLRXUnknownToLines } from './transpilers/rx-unknown/transpile-reactive-html-rx-unknown-to-lines';

export interface ITranspileReactiveHTMLRXComponentToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export const transpileReactiveHTMLRXComponentToJSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveHTMLRXComponentToJSLinesOptions]>(() => [
  transpileReactiveHTMLRXTemplateToJSLines,
  transpileReactiveHTMLRXSwitchToJSLines,
  transpileReactiveHTMLRXIfToJSLines,
  transpileReactiveHTMLRXAsyncToJSLines,
  transpileReactiveHTMLRXForLoopToJSLines,
  transpileReactiveHTMLRXContainerToJSLines,
  transpileReactiveHTMLRXScriptToJSLines,
  // transpileReactiveHTMLRXInjectContentToJSLines,
  transpileReactiveHTMLRXInjectTemplateToLines,
  transpileReactiveHTMLRXInjectSlotToLines,
  transpileReactiveHTMLRXUnknownToLines,
]);
