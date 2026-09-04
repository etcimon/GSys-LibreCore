import {
  InferCaseInsensitiveDataKeyOfVirtualComponentNode,
} from '../../case-insensitive/get-case-insensitive-data-key-of-virtual-component-node';
import { InferDataOutputKeys } from '../infer-data-outputs.type';

export type InferCaseInsensitiveDataOutputKey<GData extends object, GCaseInsensitiveKey extends string> =
  Extract<InferCaseInsensitiveDataKeyOfVirtualComponentNode<GData, GCaseInsensitiveKey>, InferDataOutputKeys<GData>>
  ;
