import { isValidCSSIdentifier } from '../../../../../../../../../dom-manipulation/helpers/misc/tokenizers/css';
import { ILinesOrNull } from '../../../../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../../primary/primary-transpilers.type';
import { IBindProperty } from '../../extract-bind-property-from-reactive-html-attribute';
import { generateJSLinesForReactiveClass } from './generate-js-lines-for-reactive-class';
import { generateJSLinesForReactiveClassNamesList } from './generate-reactive-dom-js-lines-for-reactive-class-list';

const REACTIVE_CLASS_STANDARD_REGEXP: RegExp = new RegExp('^class\\.(.*)$');
const REACTIVE_CLASS_PREFIXED_REGEXP: RegExp = new RegExp('^class-(.*)');

/**
 * Syntax:
 *  - standard:
 *    [class.class-a]="boolean"
 *    [class...]="['class-a', 'class-b']"
 *
 *  - prefixed:
 *    bind-class-class-a="boolean"
 *    bind-class---="['class-a', 'class-b']"
 */

export interface ITranspileReactiveHTMLReactiveClassToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly bindProperty: IBindProperty;
}

export function transpileReactiveHTMLReactiveClassToJSLines(
  {
    bindProperty,
    ...options
  }: ITranspileReactiveHTMLReactiveClassToJSLinesOptions,
): ILinesOrNull {
  const match: RegExpExecArray | null = bindProperty.prefixMode
    ? REACTIVE_CLASS_PREFIXED_REGEXP.exec(bindProperty.name)
    : REACTIVE_CLASS_STANDARD_REGEXP.exec(bindProperty.name);

  if (match === null) {
    return null;
  } else {
    let className: string = match[1];

    if (bindProperty.prefixMode && (className === '--')) {
      className = '..';
    }

    if ((className !== '..') && !isValidCSSIdentifier(className)) {
      throw new Error(`Invalid className '${className}'`);
    }

    return (className === '..')
      ? generateJSLinesForReactiveClassNamesList({
        ...options,
        value: bindProperty.value,
      })
      : generateJSLinesForReactiveClass({
        ...options,
        name: className,
        value: bindProperty.value,
      });
  }
}

