import { dashCaseToCamelCase } from '../../../../../../../../misc/case-converters/dash-case';
import { inlineLastLines } from '../../../../../../../../misc/lines/functions/after-last-line';
import { wrapLinesWithCurlyBrackets } from '../../../../../../../../misc/lines/functions/wrap-lines-with-curly-brackets';
import { ILinesOrNull } from '../../../../../../../../misc/lines/lines-or-null.type';
import { ILetProperty } from '../../extract-attributes/extract-let-property-from-reactive-html-attribute';

export function generateLetPropertyLinesForTemplate(
  letProperties: ILetProperty[],
): ILinesOrNull {
  return (letProperties.length === 0)
    ? null
    : inlineLastLines(
      wrapLinesWithCurlyBrackets(
        letProperties.map((letProperty: ILetProperty): string => {
          const name: string = dashCaseToCamelCase(letProperty.name);
          const value: string = letProperty.value;
          return ((value === name) || (value === ''))
            ? `${name},`
            : `${name}: ${value},`;
        }),
        false,
      ),
      [','],
    );
}
