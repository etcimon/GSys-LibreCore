import {
  InferCaseInsensitiveDataKeyOfVirtualComponentNode,
} from '../../case-insensitive/get-case-insensitive-data-key-of-virtual-component-node';
import { InferDataInputKeys } from '../infer-data-inputs.type';

export type InferCaseInsensitiveDataInputKey<GData extends object, GCaseInsensitiveKey extends string> =
  Extract<InferCaseInsensitiveDataKeyOfVirtualComponentNode<GData, GCaseInsensitiveKey>, InferDataInputKeys<GData>>
  ;
