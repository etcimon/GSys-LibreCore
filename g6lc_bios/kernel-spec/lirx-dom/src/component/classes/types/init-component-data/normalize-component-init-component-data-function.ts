import { freeze } from '@lirx/core';
import {
  IComponentInitComponentDataFunction,
  IComponentInitVoidComponentDataFunction,
} from './component-init-component-data-function.type';

const DEFAULT_COMPONENT_DATA: Readonly<object> = freeze({});
const DEFAULT_INIT_COMPONENT_DATA_FUNCTION: IComponentInitComponentDataFunction<object> = () => DEFAULT_COMPONENT_DATA;

export function normalizeComponentInitComponentDataFunction<GData extends object>(
  input: IComponentInitVoidComponentDataFunction<GData> | undefined,
): IComponentInitComponentDataFunction<GData> {
  return (input === void 0)
    ? DEFAULT_INIT_COMPONENT_DATA_FUNCTION as IComponentInitComponentDataFunction<GData>
    : (): GData => {
      return input() ?? DEFAULT_COMPONENT_DATA as GData;
    };
}
