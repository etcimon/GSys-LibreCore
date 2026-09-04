import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { indentLines } from '../../../../../misc/lines/functions/indent-lines';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  IRawModifier,
  ITranspileApplyNodeModifiersToJSLinesFunction,
  ITranspileApplyNodeModifiersToJSLinesOptions,
} from '../../transpilers/transpile-apply-node-modifiers-to-js-lines.type';

export const transpileApplyNodeModifiersToJSLines: ITranspileApplyNodeModifiersToJSLinesFunction = (
  {
    node,
    modifiers,
  }: ITranspileApplyNodeModifiersToJSLinesOptions,
): ILines => {
  return [
    `applyNodeModifiers(`,
    ...indentLines([
      ...inlineLastLines(
        node,
        [`,`],
      ),
      `[`,
      ...indentLines(
        modifiers.flatMap(({ name, value, weight }: IRawModifier): ILines => {
          return inlineLastLines(
            [`[`],
            [
              (weight === void 0)
                ? `void 0`
                : String(weight),
            ],
            [`,`],
            [JSON.stringify(name)],
            [`,`],
            value,
            [`],`],
          );
        }),
      ),
      `],`,
    ]),
    `)`,
  ];
};


