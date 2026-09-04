import { unknownToObservableNotUndefined } from '@lirx/core';
import {
  virtualElementNodeAppendClassName,
} from '../../../../../dom-manipulation/virtual-nodes/virtual-element-node/members/class-name/virtual-element-node-append-class-name';
import {
  VirtualReactiveAsyncNode,
} from '../../../../../dom-manipulation/virtual-nodes/virtual-reactive-async-node/virtual-reactive-async-node.class';
import {
  VirtualReactiveElementNode,
} from '../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/virtual-reactive-element-node.class';
import {
  VirtualReactiveForLoopNode,
} from '../../../../../dom-manipulation/virtual-nodes/virtual-reactive-for-loop-node/virtual-reactive-for-loop-node.class';
import {
  VirtualReactiveIfNode,
} from '../../../../../dom-manipulation/virtual-nodes/virtual-reactive-if-node/virtual-reactive-if-node.class';
import {
  VirtualReactiveSwitchNode,
} from '../../../../../dom-manipulation/virtual-nodes/virtual-reactive-switch-node/virtual-reactive-switch-node.class';
import {
  VirtualReactiveTextNode,
} from '../../../../../dom-manipulation/virtual-nodes/virtual-reactive-text-node/virtual-reactive-text-node.class';
import { VirtualTextNode } from '../../../../../dom-manipulation/virtual-nodes/virtual-text-node/virtual-text-node';
import { computationToObservable } from '../shared/functions/computation-to-observable';
import { SHARED_VALUES_TO_IMPORT } from '../shared/values-to-import/shared-values-to-import.constant';
import {
  bindCaseInsensitiveOutputWithObserverLike,
} from '../../../../../dom-manipulation/virtual-nodes/virtual-component-node/data/outputs/case-insensitive/bind/bind-case-insensitive-output-with-observer-like';
import {
  bindCaseInsensitiveOutputWithObservableOfObserver,
} from '../../../../../dom-manipulation/virtual-nodes/virtual-component-node/data/outputs/case-insensitive/bind/bind-case-insensitive-output-with-observable-of-observer';
import {
  bindCaseInsensitivePropertyWithObservable,
} from '../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/members/property/case-insensitive/bind/bind-case-insensitive-property-with-observable';
import {
  bindCaseInsensitiveInputWithObservable,
} from '../../../../../dom-manipulation/virtual-nodes/virtual-component-node/data/inputs/case-insensitive/bind/bind-case-insensitive-input-with-observable';

export const VALUES_TO_IMPORT_FOR_VIRTUAL_NODE_BASED_REACTIVE_HTML = {
  ...SHARED_VALUES_TO_IMPORT,
  VirtualTextNode,
  VirtualReactiveElementNode,
  VirtualReactiveTextNode,
  VirtualReactiveIfNode,
  VirtualReactiveSwitchNode,
  VirtualReactiveForLoopNode,
  VirtualReactiveAsyncNode,
  unknownToObservableNotUndefined,
  computationToObservable,
  virtualElementNodeAppendClassName,
  bindCaseInsensitivePropertyWithObservable,
  bindCaseInsensitiveInputWithObservable,
  bindCaseInsensitiveOutputWithObservableOfObserver,
  bindCaseInsensitiveOutputWithObserverLike,
};
