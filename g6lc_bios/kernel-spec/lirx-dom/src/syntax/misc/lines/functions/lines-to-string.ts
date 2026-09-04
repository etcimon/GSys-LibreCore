import { ILines } from '../lines.type';

export function linesToString(
  lines: ILines,
  separator: string = '\n',
): string {
  return lines.join(separator);
}
