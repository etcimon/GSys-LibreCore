import { IObservableLike, unknownToObservableNotUndefined, IObservable } from '@lirx/core';
import {
  IVirtualReactiveSwitchNodeTemplate,
  VirtualReactiveSwitchNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-switch-node/virtual-reactive-switch-node.class';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { indentLines } from '../../../../../misc/lines/functions/indent-lines';
import { ILines } from '../../../../../misc/lines/lines.type';
import { generateJSLinesForLinesMap } from '../../../../../misc/misc/generate-js-lines-for-lines-map';
import {
  ITranspileCreateReactiveSwitchNodeToJSLinesFunction,
  ITranspileCreateReactiveSwitchNodeToJSLinesOptions,
} from '../../transpilers/transpile-create-reactive-switch-node-to-js-lines.type';
import {
  transpileAOTReactiveValueTypeToFunctionName,
  transpileAOTReactiveValueToJSLines,
} from './special/transpile-reactive-value-to-js-lines';
import { computationToObservable } from '../../shared/functions/computation-to-observable';

export const transpileAOTCreateReactiveSwitchNodeToJSLines: ITranspileCreateReactiveSwitchNodeToJSLinesFunction = (
  {
    expression,
    templatesMap,
    defaultTemplate,
  }: ITranspileCreateReactiveSwitchNodeToJSLinesOptions,
): ILines => {
  return [
    `${transpileAOTReactiveValueTypeToFunctionName('aot_8', expression.type)}(`,
    ...indentLines([
      ...inlineLastLines(
        transpileAOTReactiveValueToJSLines(expression),
        [','],
      ),
      ...inlineLastLines(
        generateJSLinesForLinesMap({
          linesMap: templatesMap,
        }),
        [','],
      ),
      ...(
        ((defaultTemplate === null) || (defaultTemplate.length === 0))
          ? []
          : inlineLastLines(
            defaultTemplate,
            [','],
          )
      ),
    ]),
    `)`,
  ];
};

export function aot_8<GValue>(
  value$: IObservableLike<GValue>,
  templatesMap: ReadonlyMap<GValue, IVirtualReactiveSwitchNodeTemplate>,
  defaultTemplate?: IVirtualReactiveSwitchNodeTemplate,
): VirtualReactiveSwitchNode<GValue> {
  return new VirtualReactiveSwitchNode<GValue>(
    unknownToObservableNotUndefined(value$) as IObservable<GValue>,
    templatesMap,
    defaultTemplate,
  );
}

export function aot_8_computed<GValue>(
  value: () => GValue,
  templatesMap: ReadonlyMap<GValue, IVirtualReactiveSwitchNodeTemplate>,
  defaultTemplate?: IVirtualReactiveSwitchNodeTemplate,
): VirtualReactiveSwitchNode<GValue> {
  return new VirtualReactiveSwitchNode<GValue>(
    computationToObservable(value),
    templatesMap,
    defaultTemplate,
  );
}
