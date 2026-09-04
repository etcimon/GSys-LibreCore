import { IObservable, IObserver } from '@lirx/core';
import { IUnsubscribe } from '@lirx/unsubscribe';
import {
  IGenericVirtualReactiveElementNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/generic-virtual-reactive-element-node.type';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileSetReactiveEventListenerToJSLinesFunction,
  ITranspileSetReactiveEventListenerToJSLinesOptions,
} from '../../transpilers/transpile-set-reactive-event-listener-to-js-lines.type';

export const transpileAOTSetReactiveEventListenerToJSLines: ITranspileSetReactiveEventListenerToJSLinesFunction = (
  {
    node,
    name,
    value,
    observableMode,
  }: ITranspileSetReactiveEventListenerToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    [
      observableMode
        ? `aot_14(`
        : `aot_15(`,
    ],
    node,
    [', '],
    name,
    [', '],
    value,
    [');'],
  );
};

export function aot_14<GEvent extends Event>(
  node: IGenericVirtualReactiveElementNode,
  type: string,
  observable: IObservable<IObserver<GEvent>>,
  options?: boolean | AddEventListenerOptions,
): IUnsubscribe {
  return node.setReactiveEventListener<GEvent>(
    type,
    observable,
    options,
  );
}

export function aot_15<GEvent extends Event>(
  node: IGenericVirtualReactiveElementNode,
  type: string,
  observer: IObserver<GEvent>,
  options?: boolean | AddEventListenerOptions,
): IUnsubscribe {
  return node.setEventListener<GEvent>(
    type,
    observer,
    options,
  );
}


