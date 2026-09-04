import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import { extractBindPropertyFromReactiveHTMLAttribute, IBindProperty } from './extract-bind-property-from-reactive-html-attribute';
import {
  transpileReactiveHTMLReactiveAttributeToJSLines,
} from './transpilers/reactive-attribute/transpile-reactive-html-reactive-attribute-to-js-lines';
import {
  transpileReactiveHTMLReactiveClassToJSLines,
} from './transpilers/reactive-class/transpile-reactive-html-reactive-class-to-reactive-dom-js-lines';
import {
  transpileReactiveHTMLReactiveInputToJSLines,
} from './transpilers/reactive-input/transpile-reactive-html-reactive-input-to-js-lines';
import {
  transpileReactiveHTMLReactivePropertyToJSLines,
} from './transpilers/reactive-property/transpile-reactive-html-reactive-property-to-js-lines';
import {
  transpileReactiveHTMLReactiveStyleToJSLines,
} from './transpilers/reactive-style/transpile-reactive-html-reactive-style-to-js-lines';

export interface ITranspileReactiveHTMLBindPropertyToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly bindProperty: IBindProperty;
}

export const transpileReactiveHTMLBindPropertyToJSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveHTMLBindPropertyToJSLinesOptions]>(() => [
  transpileReactiveHTMLReactiveAttributeToJSLines,
  transpileReactiveHTMLReactiveClassToJSLines,
  transpileReactiveHTMLReactiveStyleToJSLines,
  transpileReactiveHTMLReactiveInputToJSLines,
  transpileReactiveHTMLReactivePropertyToJSLines,
]);

/*--------------------*/

export interface ITranspileReactiveHTMLBindPropertyAttributeToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly attribute: Attr;
}

export const transpileReactiveHTMLBindPropertyAttributeToJSLines = (
  {
    attribute,
    ...options
  }: ITranspileReactiveHTMLBindPropertyAttributeToJSLinesOptions,
): ILinesOrNull => {
  const bindProperty: IBindProperty | null = extractBindPropertyFromReactiveHTMLAttribute(attribute);
  return (bindProperty === null)
    ? null
    : transpileReactiveHTMLBindPropertyToJSLines({
      ...options,
      bindProperty,
    });
};

