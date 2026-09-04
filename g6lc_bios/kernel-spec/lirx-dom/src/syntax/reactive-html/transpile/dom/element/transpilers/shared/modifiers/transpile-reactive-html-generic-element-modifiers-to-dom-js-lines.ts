import { inlineLastLines } from '../../../../../../../misc/lines/functions/after-last-line';
import { wrapLinesWithCurlyBrackets } from '../../../../../../../misc/lines/functions/wrap-lines-with-curly-brackets';
import { ILines } from '../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../primary/primary-transpilers.type';
import { IRawModifier } from '../../../../../primary/transpilers/transpile-apply-node-modifiers-to-js-lines.type';
import { IModifierProperty } from './extract-modifier-property-from-reactive-html-attribute';

const TMP_NODE_NAME = '_node';

export interface ITranspileReactiveHTMLGenericElementModifiersToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly modifiers: IModifierProperty[];
  readonly lines: ILines;
}

export function transpileReactiveHTMLGenericElementModifiersToJSLines(
  {
    modifiers,
    lines,
    transpilers,
  }: ITranspileReactiveHTMLGenericElementModifiersToJSLinesOptions,
): ILines {
  const {
    transpileApplyNodeModifiersToJSLines,
  } = transpilers;

  return modifiers.length === 0
    ? lines
    : [
      `// modifiers`,
      ...wrapLinesWithCurlyBrackets([
        `const ${TMP_NODE_NAME} = node;`,
        ...wrapLinesWithCurlyBrackets([
          ...inlineLastLines(
            [`const node = (`],
            transpileApplyNodeModifiersToJSLines({
              node: [TMP_NODE_NAME],
              modifiers: modifiers.map(({ name, value, weight }: IModifierProperty): IRawModifier => {
                return {
                  name,
                  value: [value],
                  weight,
                };
              }),
            }),
            [');'],
          ),
          ...lines,
        ]),
      ]),
    ];
}
