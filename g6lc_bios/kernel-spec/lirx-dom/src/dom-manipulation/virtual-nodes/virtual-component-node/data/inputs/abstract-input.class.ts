import { IObserver, IObservable } from '@lirx/core';

/**
 * Represents an "abstract" Input.
 *
 * It is abstract, as many implementations may exist.
 */
export abstract class AbstractInput<GValue> {

  abstract get emit(): IObserver<GValue>;

  abstract get subscribe(): IObservable<GValue> ;

  abstract get value(): GValue;
}

export type IGenericAbstractInput = AbstractInput<any>;


