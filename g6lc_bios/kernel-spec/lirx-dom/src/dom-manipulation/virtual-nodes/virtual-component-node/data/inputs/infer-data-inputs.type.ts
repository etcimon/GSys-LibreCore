import { AsymmetricInput } from './asymmetric-input.class';
import { IGenericAbstractInput, AbstractInput } from './abstract-input.class';

export type InferDataInputs<GData extends object> = {
  [GKey in keyof GData as (GData[GKey] extends IGenericAbstractInput
    ? GKey
    : never)]: GData[GKey] extends IGenericAbstractInput
    ? GData[GKey]
    : never;
};

export type InferDataInputKeys<GData extends object> = Extract<keyof GData, keyof InferDataInputs<GData>>;

export type InferDataInputGetValue<GInput> =
  GInput extends AbstractInput<infer GValue>
    ? GValue
    : never
  ;

export type InferDataInputSetValue<GInput> =
  GInput extends AsymmetricInput<infer GValue, any>
    ? GValue
    : (
      GInput extends AbstractInput<infer GValue>
        ? GValue
        : never
      )
  ;

// export type InferDataInputGetValue<GInput> =
//   GInput extends AsymmetricInput<any, infer GValue>
//     ? GValue
//     : (
//       GInput extends Input<infer GValue>
//         ? GValue
//         : never
//       )
//   ;
//
// export type InferDataInputSetValue<GInput> =
//   GInput extends AsymmetricInput<infer GValue, any>
//     ? GValue
//     : (
//       GInput extends Input<infer GValue>
//         ? GValue
//         : never
//       )
//   ;
