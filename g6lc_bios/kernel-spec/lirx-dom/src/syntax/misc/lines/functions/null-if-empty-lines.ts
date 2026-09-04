import { ILinesOrNull } from '../lines-or-null.type';
import { ILines } from '../lines.type';

export function nullIfEmptyLines(
  lines: ILines,
): ILinesOrNull {
  return (lines.length === 0)
    ? null
    : lines;
}
