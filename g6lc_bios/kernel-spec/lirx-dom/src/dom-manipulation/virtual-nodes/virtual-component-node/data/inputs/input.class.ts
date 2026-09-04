import {
  IObserver,
  createMulticastReplayLastSource,
  IObservable,
  ICreateReplayLastSourceInitialValue,
  IMulticastReplayLastSource,
} from '@lirx/core';
import { AbstractInput } from './abstract-input.class';

/**
 * This is the "main" Input.
 */
export class Input<GValue> extends AbstractInput<GValue> {
  readonly #source: IMulticastReplayLastSource<GValue>;

  constructor(
    ...initialValue: ICreateReplayLastSourceInitialValue<GValue>
  ) {
    super();
    this.#source = createMulticastReplayLastSource<GValue>(...initialValue);
  }

  override get emit(): IObserver<GValue> {
    return this.#source.emit;
  }

  override get subscribe(): IObservable<GValue> {
    return this.#source.subscribe;
  }

  override get value(): GValue {
    return this.#source.getValue();
  }
}

export type IGenericInput = Input<any>;

export function input<GValue>(
  ...initialValue: ICreateReplayLastSourceInitialValue<GValue>
): Input<GValue> {
  return new Input<GValue>(...initialValue);
}

