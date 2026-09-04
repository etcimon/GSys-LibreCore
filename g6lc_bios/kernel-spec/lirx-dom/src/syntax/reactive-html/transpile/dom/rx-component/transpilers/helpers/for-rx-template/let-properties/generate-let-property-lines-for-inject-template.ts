import { dashCaseToCamelCase } from '../../../../../../../../misc/case-converters/dash-case';
import { createLetPropertyRequiresAValueError } from '../../../../../../../../misc/errors/create-let-property-requires-a-value-error';
import { inlineLastLines } from '../../../../../../../../misc/lines/functions/after-last-line';
import { wrapLinesWithCurlyBrackets } from '../../../../../../../../misc/lines/functions/wrap-lines-with-curly-brackets';
import { ILines } from '../../../../../../../../misc/lines/lines.type';
import { ILetProperty } from '../../extract-attributes/extract-let-property-from-reactive-html-attribute';

export function generateLetPropertyLinesForInjectTemplate(
  letProperties: ILetProperty[],
  node: Element,
): ILines {
  return inlineLastLines(
    wrapLinesWithCurlyBrackets(
      letProperties.map((letProperty: ILetProperty): string => {
        const name: string = dashCaseToCamelCase(letProperty.name);
        const value: string = letProperty.value;
        if (value === '') {
          throw createLetPropertyRequiresAValueError(letProperty.name, node);
        } else {
          return ((value === name) || (value === ''))
            ? `${name},`
            : `${name}: ${value},`;
        }
      }),
      false,
    ),
    [','],
  );
}
