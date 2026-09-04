import { ILines } from '../../../../../../../misc/lines/lines.type';
import {
  ITranspileCreateReactiveCustomElementNodeToJSLinesOptionsSlotsMap,
} from '../../../../../primary/transpilers/transpile-create-reactive-custom-element-node-to-js-lines.type';

export function deleteEmptySlots(
  slots: ITranspileCreateReactiveCustomElementNodeToJSLinesOptionsSlotsMap,
): void {
  const iterator: Iterator<[string, ILines]> = slots.entries();
  let result: IteratorResult<[string, ILines]>;
  while (!(result = iterator.next()).done) {
    const [key, value] = result.value;
    if (value.length === 0) {
      slots.delete(key);
    }
  }
}
