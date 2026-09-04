import { ILines } from '../lines.type';
import { indentLines } from './indent-lines';
import { linesToString } from './lines-to-string';

// export function wrapLinesWithBrackets(
//   start: string,
//   lines: ILines,
//   end: string,
// ): ILines {
//   return [
//     start,
//     ...indentLines(lines),
//     end,
//   ];
// }

export function wrapLinesWithBrackets(
  start: string,
  lines: ILines,
  end: string,
  inlineIfSingleLine: boolean = true,
): ILines {
  return (inlineIfSingleLine && lines.length <= 1)
    ? [`${start}${linesToString(lines)}${end}`]
    : [
      start,
      ...indentLines(lines),
      end,
    ];
}
