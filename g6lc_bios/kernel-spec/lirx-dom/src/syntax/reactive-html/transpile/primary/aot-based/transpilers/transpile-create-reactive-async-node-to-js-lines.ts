import { IDefaultNotificationsUnion, IObservableLike, unknownToObservableNotUndefined } from '@lirx/core';
import {
  IVirtualReactiveAsyncNodeFulfilledTemplate,
  IVirtualReactiveAsyncNodePendingTemplate,
  IVirtualReactiveAsyncNodeRejectedTemplate,
  VirtualReactiveAsyncNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-async-node/virtual-reactive-async-node.class';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { indentLines } from '../../../../../misc/lines/functions/indent-lines';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileCreateReactiveAsyncNodeToJSLinesFunction,
  ITranspileCreateReactiveAsyncNodeToJSLinesOptions,
} from '../../transpilers/transpile-create-reactive-async-node-to-js-lines.type';

export const transpileAOTCreateReactiveAsyncNodeToJSLines: ITranspileCreateReactiveAsyncNodeToJSLinesFunction = (
  {
    expression,
    templatePending,
    templateFulfilled,
    templateRejected,
  }: ITranspileCreateReactiveAsyncNodeToJSLinesOptions,
): ILines => {
  return [
    `aot_1(`,
    ...indentLines([
      ...inlineLastLines(
        expression,
        [','],
      ),
      ...inlineLastLines(
        templatePending,
        [','],
      ),
      ...inlineLastLines(
        templateFulfilled,
        [','],
      ),
      ...inlineLastLines(
        templateRejected,
        [','],
      ),
    ]),
    `)`,
  ];
};

export function aot_1<GValue>(
  value$: IObservableLike<IDefaultNotificationsUnion<GValue>>,
  templatePending: IVirtualReactiveAsyncNodePendingTemplate | null = null,
  templateFulfilled: IVirtualReactiveAsyncNodeFulfilledTemplate<GValue> | null = null,
  templateRejected: IVirtualReactiveAsyncNodeRejectedTemplate<GValue> | null = null,
): VirtualReactiveAsyncNode<GValue> {
  return new VirtualReactiveAsyncNode<GValue>(
    unknownToObservableNotUndefined(value$),
    templatePending,
    templateFulfilled,
    templateRejected,
  );
}


