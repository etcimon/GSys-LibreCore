import { ILines } from '../lines/lines.type';

export function generateJsLinesForValuesToImportFromObject(
  valuesToImport: object,
): ILines {
  return Object.keys(valuesToImport).map((value: string): string => {
    return `${value},`;
  });
}
