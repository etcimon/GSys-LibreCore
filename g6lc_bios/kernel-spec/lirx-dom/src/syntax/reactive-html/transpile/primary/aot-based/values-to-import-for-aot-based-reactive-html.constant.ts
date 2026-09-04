import { SHARED_VALUES_TO_IMPORT } from '../shared/values-to-import/shared-values-to-import.constant';
import { aot_0 } from './transpilers/transpile-attach-node-to-js-lines';
import { aot_1 } from './transpilers/transpile-create-reactive-async-node-to-js-lines';
import { aot_2, aot_3, aot_4, aot_5 } from './transpilers/transpile-create-reactive-element-node-to-js-lines';
import { aot_6, aot_6_computed } from './transpilers/transpile-create-reactive-for-loop-node-to-js-lines';
import { aot_7, aot_7_computed } from './transpilers/transpile-create-reactive-if-node-to-js-lines';
import { aot_8, aot_8_computed } from './transpilers/transpile-create-reactive-switch-node-to-js-lines';
import { aot_9, aot_9_computed } from './transpilers/transpile-create-reactive-text-node-to-js-lines';
import { aot_10 } from './transpilers/transpile-create-static-text-node-to-js-lines';
import { aot_11, aot_11_computed } from './transpilers/transpile-set-reactive-attribute-to-js-lines';
import { aot_12, aot_12_computed } from './transpilers/transpile-set-reactive-class-names-list-to-js-lines';
import { aot_13, aot_13_computed } from './transpilers/transpile-set-reactive-class-to-js-lines';
import { aot_14, aot_15 } from './transpilers/transpile-set-reactive-event-listener-to-js-lines';
import { aot_16, aot_16_computed } from './transpilers/transpile-set-reactive-input-to-js-lines';
import { aot_17, aot_18 } from './transpilers/transpile-set-reactive-output-to-js-lines';
import { aot_19, aot_19_computed } from './transpilers/transpile-set-reactive-property-to-js-lines';
import { aot_20, aot_20_computed } from './transpilers/transpile-set-reactive-style-properties-map-to-js-lines';
import { aot_21, aot_21_computed } from './transpilers/transpile-set-reactive-style-property-to-js-lines';
import { aot_22, aot_23 } from './transpilers/transpile-set-static-attribute-to-js-lines';
import { computationToObservable } from '../shared/functions/computation-to-observable';

export const VALUES_TO_IMPORT_FOR_AOT_BASED_REACTIVE_HTML = {
  ...SHARED_VALUES_TO_IMPORT,
  computationToObservable,
  aot_0,
  aot_1,
  aot_2,
  aot_3,
  aot_4,
  aot_5,
  aot_6,
  aot_6_computed,
  aot_7,
  aot_7_computed,
  aot_8,
  aot_8_computed,
  aot_9,
  aot_9_computed,
  aot_10,
  aot_11,
  aot_11_computed,
  aot_12,
  aot_12_computed,
  aot_13,
  aot_13_computed,
  aot_14,
  aot_15,
  aot_16,
  aot_16_computed,
  aot_17,
  aot_18,
  aot_19,
  aot_19_computed,
  aot_20,
  aot_20_computed,
  aot_21,
  aot_21_computed,
  aot_22,
  aot_23,
};
