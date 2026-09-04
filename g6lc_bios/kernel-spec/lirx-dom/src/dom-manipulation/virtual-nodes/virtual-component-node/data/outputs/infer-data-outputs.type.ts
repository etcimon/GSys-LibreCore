import { Output, IGenericOutput } from './output.class';

export type InferDataOutputs<GData extends object> = {
  [GKey in keyof GData as (GData[GKey] extends IGenericOutput
    ? GKey
    : never)]: GData[GKey] extends IGenericOutput
    ? GData[GKey]
    : never;
};

export type InferDataOutputKeys<GData extends object> = Extract<keyof GData, keyof InferDataOutputs<GData>>;

export type InferDataOutputValue<GInput> =
  GInput extends Output<infer GValue>
    ? GValue
    : never
  ;
