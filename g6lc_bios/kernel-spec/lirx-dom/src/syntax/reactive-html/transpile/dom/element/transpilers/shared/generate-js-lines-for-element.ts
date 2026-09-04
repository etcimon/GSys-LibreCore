import { wrapLinesWithCurlyBrackets } from '../../../../../../misc/lines/functions/wrap-lines-with-curly-brackets';
import { ILines } from '../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import {
  transpileReactiveHTMLGenericElementAttributesToJSLines,
} from './attributes/transpile-reactive-html-generic-element-attributes-to-dom-js-lines';
import {
  transpileReactiveHTMLGenericElementChildrenToJSLines,
} from './children/transpile-reactive-html-generic-element-children-to-dom-js-lines';
import {
  extractAndRemoveModifierPropertiesFromReactiveHTMLAttributes,
} from './modifiers/extract-modifier-properties-from-reactive-html-attributes';
import { IModifierProperty } from './modifiers/extract-modifier-property-from-reactive-html-attribute';
import {
  transpileReactiveHTMLGenericElementModifiersToJSLines,
} from './modifiers/transpile-reactive-html-generic-element-modifiers-to-dom-js-lines';

export interface IGenerateJSLinesForElementOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
  readonly elementLines: ILines;
  readonly modifiers?: IModifierProperty[];
  readonly attributesLines?: ILines;
  readonly childrenLines?: ILines;
}

export function generateJSLinesForElement(
  {
    node,
    elementLines,
    modifiers,
    attributesLines,
    childrenLines,
    transpilers,
  }: IGenerateJSLinesForElementOptions,
): ILines {
  const {
    transpileAttachNodeToJSLines,
  } = transpilers;

  const attachNodeLines: ILines = transpileAttachNodeToJSLines({
    node: ['node'],
    parentNode: ['parentNode'],
  });

  if (modifiers === void 0) {
    modifiers = extractAndRemoveModifierPropertiesFromReactiveHTMLAttributes(node.attributes);
  }

  if (attributesLines === void 0) {
    attributesLines = transpileReactiveHTMLGenericElementAttributesToJSLines({
      node,
      transpilers,
    });
  }

  if (childrenLines === void 0) {
    childrenLines = transpileReactiveHTMLGenericElementChildrenToJSLines({
      node,
      transpilers,
    });
  }

  const modifiersLines: ILines = transpileReactiveHTMLGenericElementModifiersToJSLines({
    modifiers,
    lines: [
      ...attributesLines,
      ...childrenLines,
      ...attachNodeLines,
    ],
    transpilers,
  });

  return wrapLinesWithCurlyBrackets([
    ...elementLines,
    ...modifiersLines,
  ]);
}

