import { ILinesOrNull } from '../lines-or-null.type';
import { ILines } from '../lines.type';

export function linesOrNullToLines(
  lines: ILinesOrNull,
): ILines {
  return (lines === null)
    ? []
    : lines;
}
