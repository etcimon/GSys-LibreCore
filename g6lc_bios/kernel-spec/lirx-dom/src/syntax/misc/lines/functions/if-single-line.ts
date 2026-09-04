import { ILines } from '../lines.type';

export function ifSingleLine(
  lines: ILines,
  singleTrue: () => ILines,
  singleFalse: () => ILines,
): ILines {
  return (lines.length <= 1)
    ? singleTrue()
    : singleFalse();
}
