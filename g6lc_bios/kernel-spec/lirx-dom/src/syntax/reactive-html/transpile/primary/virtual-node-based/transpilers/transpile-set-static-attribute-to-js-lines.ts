import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileSetStaticAttributeToJSLinesFunction,
  ITranspileSetStaticAttributeToJSLinesOptions,
} from '../../transpilers/transpile-set-static-attribute-to-js-lines.type';

export const transpileSetStaticAttributeToJSLines: ITranspileSetStaticAttributeToJSLinesFunction = (
  {
    node,
    name,
    value,
  }: ITranspileSetStaticAttributeToJSLinesOptions,
): ILines => {
  if (isClassAttribute(name)) {
    return inlineLastLines(
      [`virtualElementNodeAppendClassName(`],
      node,
      [', '],
      value,
      [');'],
    );
  } else {
    return inlineLastLines(
      node,
      [`.setAttribute(`],
      name,
      [', '],
      value,
      [');'],
    );
  }
};

/*---*/

function isClassAttribute(
  name: ILines,
): boolean {
  return (name[0] === '"class"');
}
