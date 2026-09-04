import { indentLines } from '../../../../../misc/lines/functions/indent-lines';
import { ILines } from '../../../../../misc/lines/lines.type';
import { generateJSLinesForLinesMap } from '../../../../../misc/misc/generate-js-lines-for-lines-map';
import {
  ITranspileCreateReactiveCustomElementNodeToJSLinesFunction,
  ITranspileCreateReactiveCustomElementNodeToJSLinesOptions,
} from '../../transpilers/transpile-create-reactive-custom-element-node-to-js-lines.type';

export const transpileCreateReactiveCustomElementNodeToJSLines: ITranspileCreateReactiveCustomElementNodeToJSLinesFunction = (
  {
    name,
    slots,
  }: ITranspileCreateReactiveCustomElementNodeToJSLinesOptions,
): ILines => {
  return [
    `createCustomElement(`,
    ...indentLines([
      `${JSON.stringify(name)},`,
      ...generateJSLinesForLinesMap({
        linesMap: slots,
        escapeValue: true,
      }),
    ]),
    `)`,
  ];
};

// export const transpileCreateReactiveCustomElementNodeToJSLines: ITranspileCreateReactiveCustomElementNodeToJSLinesFunction = (
//   {
//     name,
//     slots,
//   }: ITranspileCreateReactiveCustomElementNodeToJSLinesOptions,
// ): ILines => {
//   return [
//     `createCustomElement(`,
//     ...indentLines([
//       `${JSON.stringify(name)},`,
//       `new Map([`,
//       ...indentLines(
//         Array.from(slots.entries()).flatMap(([slotName, slotTemplate]: [string, ILines]): ILines => {
//           return [
//             `[`,
//             ...indentLines([
//               `${JSON.stringify(slotName)},`,
//               ...inlineLastLines(slotTemplate, [',']),
//             ]),
//             `],`,
//           ];
//         }),
//       ),
//       `])`,
//     ]),
//     `)`,
//   ];
// };
