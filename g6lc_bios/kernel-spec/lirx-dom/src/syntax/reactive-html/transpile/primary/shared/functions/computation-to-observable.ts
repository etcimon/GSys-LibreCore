import { IObservable, fromSignal, computed, IComputationFunction } from '@lirx/core';

export function computationToObservable<GValue>(
  computation: IComputationFunction<GValue>,
): IObservable<GValue> {
  return fromSignal(computed(computation));
}
