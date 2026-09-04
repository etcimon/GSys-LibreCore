import { IObservableLike, unknownToObservableNotUndefined } from '@lirx/core';
import {
  IVirtualReactiveForLoopNodeOptionsTrackByFunction,
  IVirtualReactiveForLoopNodeTemplate,
  VirtualReactiveForLoopNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-for-loop-node/virtual-reactive-for-loop-node.class';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { indentLines } from '../../../../../misc/lines/functions/indent-lines';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileCreateReactiveForLoopNodeToJSLinesFunction,
  ITranspileCreateReactiveForLoopNodeToJSLinesOptions,
} from '../../transpilers/transpile-create-reactive-for-loop-node-to-js-lines.type';
import { computationToObservable } from '../../shared/functions/computation-to-observable';
import {
  transpileAOTReactiveValueToJSLines,
  transpileAOTReactiveValueTypeToFunctionName,
} from './special/transpile-reactive-value-to-js-lines';

export const transpileAOTCreateReactiveForLoopNodeToJSLines: ITranspileCreateReactiveForLoopNodeToJSLinesFunction = (
  {
    items,
    template,
    trackBy,
  }: ITranspileCreateReactiveForLoopNodeToJSLinesOptions,
): ILines => {
  return [
    `${transpileAOTReactiveValueTypeToFunctionName('aot_6', items.type)}(`,
    ...indentLines([
      ...inlineLastLines(
        transpileAOTReactiveValueToJSLines(items),
        [','],
      ),
      ...inlineLastLines(
        template,
        [','],
      ),
      ...(
        (trackBy === null)
          ? []
          : inlineLastLines(
            trackBy,
            [','],
          )
      ),
    ]),
    `)`,
  ];
};

export function aot_6<GItem>(
  items$: IObservableLike<Iterable<GItem>>,
  template: IVirtualReactiveForLoopNodeTemplate<GItem>,
  trackBy?: IVirtualReactiveForLoopNodeOptionsTrackByFunction<GItem>,
): VirtualReactiveForLoopNode<GItem> {
  return new VirtualReactiveForLoopNode<GItem>(
    unknownToObservableNotUndefined(items$),
    template,
    trackBy,
  );
}

export function aot_6_computed<GItem>(
  items: () => Iterable<GItem>,
  template: IVirtualReactiveForLoopNodeTemplate<GItem>,
  trackBy?: IVirtualReactiveForLoopNodeOptionsTrackByFunction<GItem>,
): VirtualReactiveForLoopNode<GItem> {
  return new VirtualReactiveForLoopNode<GItem>(
    computationToObservable(items),
    template,
    trackBy,
  );
}

