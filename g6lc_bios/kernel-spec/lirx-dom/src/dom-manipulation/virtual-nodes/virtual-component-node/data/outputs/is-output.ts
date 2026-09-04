import { isNullish } from '@lirx/utils';
import { Output } from './output.class';

export function isOutput<GValue>(
  input: unknown,
): input is Output<GValue> {
  return !isNullish(input)
    && (input instanceof Output);
}
