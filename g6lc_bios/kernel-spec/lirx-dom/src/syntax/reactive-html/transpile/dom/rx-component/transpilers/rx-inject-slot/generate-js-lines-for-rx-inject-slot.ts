import { indentLines } from '../../../../../../misc/lines/functions/indent-lines';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../misc/lines/lines.type';

export interface IGenerateJSLinesForRXInjectSlotOptions {
  readonly slotName: string;
  readonly letPropertiesLines: ILines;
  readonly defaultLines: ILinesOrNull;
}

export function generateJSLinesForRXInjectSlot(
  {
    slotName,
    letPropertiesLines,
    defaultLines,
  }: IGenerateJSLinesForRXInjectSlotOptions,
): ILines {
  const elseLines: ILines = (defaultLines === null)
    ? [`}`]
    : [
      `} else {`,
      ...indentLines(defaultLines),
      `}`,
    ];

  return [
    `// inject slot '${slotName}'`,
    `if (slots.has(${JSON.stringify(slotName)})) {`,
    ...indentLines([
      `slots.get(${JSON.stringify(slotName)})(`,
      ...indentLines([
        `parentNode,`,
        ...letPropertiesLines,
      ]),
      `);`,
    ]),
    ...elseLines,
  ];
}
