import { IObserver, IObservable, ISignal, fromSignal, ICreateSignalOptions, signal } from '@lirx/core';
import { AbstractInput } from './abstract-input.class';

/**
 * This Input is based on Signal instead of a MulticastReplayLastSource.
 */
export class SignalInput<GValue> extends AbstractInput<GValue> {
  readonly #signal: ISignal<GValue>;
  readonly #emit: IObserver<GValue>;
  readonly #subscribe: IObservable<GValue>;

  constructor(
    initialValue: GValue,
    options?: ICreateSignalOptions<GValue>,
  ) {
    super();
    this.#signal = signal<GValue>(initialValue, options);

    this.#emit = (
      value: GValue,
    ): void => {
      this.#signal.set(value);
    };

    this.#subscribe = fromSignal(this.#signal);
  }

  get signal(): ISignal<GValue> {
    return this.#signal;
  }

  override get emit(): IObserver<GValue> {
    return this.#emit;
  }

  override get subscribe(): IObservable<GValue> {
    return this.#subscribe;
  }

  override get value(): GValue {
    return this.#signal();
  }
}

export type IGenericSignalInput = SignalInput<any>;

export function signalInput<GValue>(
  initialValue: GValue,
  options?: ICreateSignalOptions<GValue>,
): SignalInput<GValue> {
  return new SignalInput<GValue>(initialValue, options);
}

