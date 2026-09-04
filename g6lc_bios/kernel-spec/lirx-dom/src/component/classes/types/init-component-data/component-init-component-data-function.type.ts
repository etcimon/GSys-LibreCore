export type InferComponentOptionsInitComponentDataFunction<GData extends object> =
  object extends GData
    ? {
      componentData?: IComponentInitVoidComponentDataFunction<GData> | undefined;
    }
    : {
      componentData: IComponentInitComponentDataFunction<GData>;
    }
  ;

export interface IComponentInitComponentDataFunction<GData extends object> {
  (): GData;
}

export interface IComponentInitVoidComponentDataFunction<GData extends object> {
  (): GData | void | undefined;
}
