import { IPrimaryTranspilers } from '../primary-transpilers.type';
import { transpileAOTApplyNodeModifiersToJSLines } from './transpilers/transpile-apply-node-modifiers-to-js-lines';
import { transpileAOTAttachNodeToJSLines } from './transpilers/transpile-attach-node-to-js-lines';
import { transpileAOTCreateReactiveAsyncNodeToJSLines } from './transpilers/transpile-create-reactive-async-node-to-js-lines';
import {
  transpileAOTCreateReactiveCustomElementNodeToJSLines,
} from './transpilers/transpile-create-reactive-custom-element-node-to-js-lines';
import { transpileAOTCreateReactiveElementNodeToJSLines } from './transpilers/transpile-create-reactive-element-node-to-js-lines';
import { transpileAOTCreateReactiveForLoopNodeToJSLines } from './transpilers/transpile-create-reactive-for-loop-node-to-js-lines';
import { transpileAOTCreateReactiveIfNodeToJSLines } from './transpilers/transpile-create-reactive-if-node-to-js-lines';
import { transpileAOTCreateReactiveSwitchNodeToJSLines } from './transpilers/transpile-create-reactive-switch-node-to-js-lines';
import { transpileAOTCreateReactiveTextNodeToJSLines } from './transpilers/transpile-create-reactive-text-node-to-js-lines';
import { transpileAOTCreateStaticTextNodeToJSLines } from './transpilers/transpile-create-static-text-node-to-js-lines';
import { transpileAOTSetReactiveAttributeToJSLines } from './transpilers/transpile-set-reactive-attribute-to-js-lines';
import { transpileAOTSetReactiveClassNamesListToJSLines } from './transpilers/transpile-set-reactive-class-names-list-to-js-lines';
import { transpileAOTSetReactiveClassToJSLines } from './transpilers/transpile-set-reactive-class-to-js-lines';
import { transpileAOTSetReactiveEventListenerToJSLines } from './transpilers/transpile-set-reactive-event-listener-to-js-lines';
import { transpileAOTSetReactiveInputToJSLines } from './transpilers/transpile-set-reactive-input-to-js-lines';
import { transpileAOTSetReactiveOutputToJSLines } from './transpilers/transpile-set-reactive-output-to-js-lines';
import { transpileAOTSetReactivePropertyToJSLines } from './transpilers/transpile-set-reactive-property-to-js-lines';
import { transpileAOTSetReactiveStylePropertiesMapToJSLines } from './transpilers/transpile-set-reactive-style-properties-map-to-js-lines';
import { transpileAOTSetReactiveStylePropertyToJSLines } from './transpilers/transpile-set-reactive-style-property-to-js-lines';
import { transpileAOTSetStaticAttributeToJSLines } from './transpilers/transpile-set-static-attribute-to-js-lines';

export const PRIMARY_TRANSPILERS_FOR_AOT_BASED_REACTIVE_HTML: IPrimaryTranspilers = {
  transpileApplyNodeModifiersToJSLines: transpileAOTApplyNodeModifiersToJSLines,
  transpileAttachNodeToJSLines: transpileAOTAttachNodeToJSLines,
  transpileCreateReactiveAsyncNodeToJSLines: transpileAOTCreateReactiveAsyncNodeToJSLines,
  transpileCreateReactiveCustomElementNodeToJSLines: transpileAOTCreateReactiveCustomElementNodeToJSLines,
  transpileCreateReactiveElementNodeToJSLines: transpileAOTCreateReactiveElementNodeToJSLines,
  transpileCreateReactiveForLoopNodeToJSLines: transpileAOTCreateReactiveForLoopNodeToJSLines,
  transpileCreateReactiveIfNodeToJSLines: transpileAOTCreateReactiveIfNodeToJSLines,
  transpileCreateReactiveSwitchNodeToJSLines: transpileAOTCreateReactiveSwitchNodeToJSLines,
  transpileCreateReactiveTextNodeToJSLines: transpileAOTCreateReactiveTextNodeToJSLines,
  transpileSetReactiveAttributeToJSLines: transpileAOTSetReactiveAttributeToJSLines,
  transpileSetReactiveClassNamesListToJSLines: transpileAOTSetReactiveClassNamesListToJSLines,
  transpileSetReactiveClassToJSLines: transpileAOTSetReactiveClassToJSLines,
  transpileSetReactiveEventListenerToJSLines: transpileAOTSetReactiveEventListenerToJSLines,
  transpileCreateStaticTextNodeToJSLines: transpileAOTCreateStaticTextNodeToJSLines,
  transpileSetReactiveInputToJSLines: transpileAOTSetReactiveInputToJSLines,
  transpileSetReactiveOutputToJSLines: transpileAOTSetReactiveOutputToJSLines,
  transpileSetReactivePropertyToJSLines: transpileAOTSetReactivePropertyToJSLines,
  transpileSetReactiveStylePropertiesMapToJSLines: transpileAOTSetReactiveStylePropertiesMapToJSLines,
  transpileSetReactiveStylePropertyToJSLines: transpileAOTSetReactiveStylePropertyToJSLines,
  transpileSetStaticAttributeToJSLines: transpileAOTSetStaticAttributeToJSLines,
};
