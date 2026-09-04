import { IPrimaryTranspilers } from '../primary-transpilers.type';
import { transpileApplyNodeModifiersToJSLines } from './transpilers/transpile-apply-node-modifiers-to-js-lines';
import { transpileAttachNodeToJSLines } from './transpilers/transpile-attach-node-to-js-lines';
import { transpileCreateReactiveAsyncNodeToJSLines } from './transpilers/transpile-create-reactive-async-node-to-js-lines';
import { transpileCreateReactiveCustomElementNodeToJSLines } from './transpilers/transpile-create-reactive-custom-element-node-to-js-lines';
import { transpileCreateReactiveElementNodeToJSLines } from './transpilers/transpile-create-reactive-element-node-to-js-lines';
import { transpileCreateReactiveForLoopNodeToJSLines } from './transpilers/transpile-create-reactive-for-loop-node-to-js-lines';
import { transpileCreateReactiveIfNodeToJSLines } from './transpilers/transpile-create-reactive-if-node-to-js-lines';
import { transpileCreateReactiveSwitchNodeToJSLines } from './transpilers/transpile-create-reactive-switch-node-to-js-lines';
import { transpileCreateReactiveTextNodeToJSLines } from './transpilers/transpile-create-reactive-text-node-to-js-lines';
import { transpileCreateStaticTextNodeToJSLines } from './transpilers/transpile-create-static-text-node-to-js-lines';
import { transpileSetReactiveAttributeToJSLines } from './transpilers/transpile-set-reactive-attribute-to-js-lines';
import { transpileSetReactiveClassNamesListToJSLines } from './transpilers/transpile-set-reactive-class-names-list-to-js-lines';
import { transpileSetReactiveClassToJSLines } from './transpilers/transpile-set-reactive-class-to-js-lines';
import { transpileSetReactiveEventListenerToJSLines } from './transpilers/transpile-set-reactive-event-listener-to-js-lines';
import { transpileSetReactiveInputToJSLines } from './transpilers/transpile-set-reactive-input-to-js-lines';
import { transpileSetReactiveOutputToJSLines } from './transpilers/transpile-set-reactive-output-to-js-lines';
import { transpileSetReactivePropertyToJSLines } from './transpilers/transpile-set-reactive-property-to-js-lines';
import { transpileSetReactiveStylePropertiesMapToJSLines } from './transpilers/transpile-set-reactive-style-properties-map-to-js-lines';
import { transpileSetReactiveStylePropertyToJSLines } from './transpilers/transpile-set-reactive-style-property-to-js-lines';
import { transpileSetStaticAttributeToJSLines } from './transpilers/transpile-set-static-attribute-to-js-lines';

export const PRIMARY_TRANSPILERS_FOR_VIRTUAL_NODE_BASED_REACTIVE_HTML: IPrimaryTranspilers = {
  transpileApplyNodeModifiersToJSLines,
  transpileAttachNodeToJSLines,
  transpileCreateReactiveAsyncNodeToJSLines,
  transpileCreateReactiveCustomElementNodeToJSLines,
  transpileCreateReactiveElementNodeToJSLines,
  transpileCreateReactiveForLoopNodeToJSLines,
  transpileCreateReactiveIfNodeToJSLines,
  transpileCreateReactiveSwitchNodeToJSLines,
  transpileCreateReactiveTextNodeToJSLines,
  transpileSetReactiveAttributeToJSLines,
  transpileSetReactiveClassNamesListToJSLines,
  transpileSetReactiveClassToJSLines,
  transpileSetReactiveEventListenerToJSLines,
  transpileCreateStaticTextNodeToJSLines,
  transpileSetReactiveInputToJSLines,
  transpileSetReactiveOutputToJSLines,
  transpileSetReactivePropertyToJSLines,
  transpileSetReactiveStylePropertiesMapToJSLines,
  transpileSetReactiveStylePropertyToJSLines,
  transpileSetStaticAttributeToJSLines,
};
