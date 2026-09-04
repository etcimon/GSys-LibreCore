import { ILinesOrNull } from '../lines/lines-or-null.type';

export interface IToLinesTranspiler<GArgument extends any[]> {
  (...args: GArgument): ILinesOrNull;
}
