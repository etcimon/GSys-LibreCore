import { IObservableLike, unknownToObservableNotUndefined } from '@lirx/core';
import {
  IVirtualReactiveIfNodeTemplate,
  VirtualReactiveIfNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-if-node/virtual-reactive-if-node.class';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { indentLines } from '../../../../../misc/lines/functions/indent-lines';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileCreateReactiveIfNodeToJSLinesFunction,
  ITranspileCreateReactiveIfNodeToJSLinesOptions,
} from '../../transpilers/transpile-create-reactive-if-node-to-js-lines.type';
import {
  transpileAOTReactiveValueToJSLines,
  transpileAOTReactiveValueTypeToFunctionName,
} from './special/transpile-reactive-value-to-js-lines';
import { computationToObservable } from '../../shared/functions/computation-to-observable';

export const transpileAOTCreateReactiveIfNodeToJSLines: ITranspileCreateReactiveIfNodeToJSLinesFunction = (
  {
    condition,
    templateTrue,
    templateFalse,
  }: ITranspileCreateReactiveIfNodeToJSLinesOptions,
): ILines => {
  return [
    `${transpileAOTReactiveValueTypeToFunctionName('aot_7', condition.type)}(`,
    ...indentLines([
      ...inlineLastLines(
        transpileAOTReactiveValueToJSLines(condition),
        [','],
      ),
      ...inlineLastLines(
        // (templateTrue === null) ? ['null'] : templateTrue,
        templateTrue,
        [','],
      ),
      ...inlineLastLines(
        // (templateFalse === null) ? ['null'] : templateFalse,
        templateFalse,
        [','],
      ),
    ]),
    `)`,
  ];
};

export function aot_7(
  condition$: IObservableLike<boolean>,
  templateTrue?: IVirtualReactiveIfNodeTemplate,
  templateFalse?: IVirtualReactiveIfNodeTemplate,
): VirtualReactiveIfNode {
  return new VirtualReactiveIfNode(
    unknownToObservableNotUndefined(condition$),
    templateTrue,
    templateFalse,
  );
}

export function aot_7_computed(
  condition: () => boolean,
  templateTrue?: IVirtualReactiveIfNodeTemplate,
  templateFalse?: IVirtualReactiveIfNodeTemplate,
): VirtualReactiveIfNode {
  return new VirtualReactiveIfNode(
    computationToObservable(condition),
    templateTrue,
    templateFalse,
  );
}
