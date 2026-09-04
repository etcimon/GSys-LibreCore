import { inlineLastLines } from '../lines/functions/after-last-line';
import { indentLines } from '../lines/functions/indent-lines';
import { ILines } from '../lines/lines.type';

export type ILinesMap = Map<string, ILines>;

export interface IGenerateJSLinesFoMapOptions extends Omit<IGenerateJSLinesFoMapEntriesOptions, 'linesMapEntries'> {
  readonly linesMap: ILinesMap;
}

export function generateJSLinesForLinesMap(
  {
    linesMap,
    ...options
  }: IGenerateJSLinesFoMapOptions,
): ILines {
  return generateJSLinesForLinesMapEntries({
    ...options,
    linesMapEntries: Array.from(linesMap.entries()),
  });
}

/*--*/

export interface IGenerateJSLinesFoMapEntriesOptions {
  linesMapEntries: readonly [string, ILines][];
  escapeValue?: boolean;
}

export function generateJSLinesForLinesMapEntries(
  {
    linesMapEntries,
    escapeValue = false,
  }: IGenerateJSLinesFoMapEntriesOptions,
): ILines {
  if (linesMapEntries.length === 0) {
    return [`new Map()`];
  } else {
    return [
      `new Map([`,
      ...indentLines(
        linesMapEntries.flatMap(([value, lines]: [string, ILines]): ILines => {
          return [
            `[`,
            ...indentLines([
              `${escapeValue ? JSON.stringify(value) : value},`,
              ...inlineLastLines(lines, [',']),
            ]),
            `],`,
          ];
        }),
      ),
      `])`,
    ];
  }
}
