import { IObserver, IObservable, createMulticastSource, IMulticastSource } from '@lirx/core';

export class Output<GValue> {
  readonly #source: IMulticastSource<GValue>;

  constructor() {
    this.#source = createMulticastSource<GValue>();
  }

  get emit(): IObserver<GValue> {
    return this.#source.emit;
  }

  get subscribe(): IObservable<GValue> {
    return this.#source.subscribe;
  }
}

export type IGenericOutput = Output<any>;

export function output<GValue>(): Output<GValue> {
  return new Output<GValue>();
}



