import { ILinesOrNull } from '../lines/lines-or-null.type';
import { IToLinesTranspiler } from '../types/to-lines.transpiler.type';

export function createGenericToLinesIteratorTranspilerWithAsyncReference<GArgument extends any[]>(
  getTranspilers: () => ArrayLike<IToLinesTranspiler<GArgument>>,
): IToLinesTranspiler<GArgument> {
  return (
    ...args: GArgument
  ): ILinesOrNull => {
    const transpilers: ArrayLike<IToLinesTranspiler<GArgument>> = getTranspilers();
    for (let i = 0, l = transpilers.length; i < l; i++) {
      const result: ILinesOrNull = transpilers[i](...args);
      if (result !== null) {
        return result;
      }
    }
    return null;
  };
}
