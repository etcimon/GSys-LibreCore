import { ITranspileApplyNodeModifiersToJSLinesTrait } from './transpilers/transpile-apply-node-modifiers-to-js-lines.type';
import { ITranspileAttachNodeToJSLinesTrait } from './transpilers/transpile-attach-node-to-js-lines.type';
import { ITranspileCreateReactiveAsyncNodeToJSLinesTrait } from './transpilers/transpile-create-reactive-async-node-to-js-lines.type';
import {
  ITranspileCreateReactiveCustomElementNodeToJSLinesTrait,
} from './transpilers/transpile-create-reactive-custom-element-node-to-js-lines.type';
import { ITranspileCreateReactiveElementNodeToJSLinesTrait } from './transpilers/transpile-create-reactive-element-node-to-js-lines.type';
import { ITranspileCreateReactiveForLoopNodeToJSLinesTrait } from './transpilers/transpile-create-reactive-for-loop-node-to-js-lines.type';
import { ITranspileCreateReactiveIfNodeToJSLinesTrait } from './transpilers/transpile-create-reactive-if-node-to-js-lines.type';
import { ITranspileCreateReactiveSwitchNodeToJSLinesTrait } from './transpilers/transpile-create-reactive-switch-node-to-js-lines.type';
import { ITranspileCreateReactiveTextNodeToJSLinesTrait } from './transpilers/transpile-create-reactive-text-node-to-js-lines.type';
import { ITranspileCreateStaticTextNodeToJSLinesTrait } from './transpilers/transpile-create-static-text-node-to-js-lines.type';
import { ITranspileSetReactiveAttributeToJSLinesTrait } from './transpilers/transpile-set-reactive-attribute-to-js-lines.type';
import { ITranspileSetReactiveClassNamesListToJSLinesTrait } from './transpilers/transpile-set-reactive-class-names-list-to-js-lines.type';
import { ITranspileSetReactiveClassToJSLinesTrait } from './transpilers/transpile-set-reactive-class-to-js-lines.type';
import { ITranspileSetReactiveEventListenerToJSLinesTrait } from './transpilers/transpile-set-reactive-event-listener-to-js-lines.type';
import { ITranspileSetReactiveInputToJSLinesTrait } from './transpilers/transpile-set-reactive-input-to-js-lines.type';
import { ITranspileSetReactiveOutputToJSLinesTrait } from './transpilers/transpile-set-reactive-output-to-js-lines.type';
import { ITranspileSetReactivePropertyToJSLinesTrait } from './transpilers/transpile-set-reactive-property-to-js-lines.type';
import {
  ITranspileSetReactiveStylePropertiesMapToJSLinesTrait,
} from './transpilers/transpile-set-reactive-style-properties-map-to-js-lines.type';
import { ITranspileSetReactiveStylePropertyToJSLinesTrait } from './transpilers/transpile-set-reactive-style-property-to-js-lines.type';
import { ITranspileSetStaticAttributeToJSLinesTrait } from './transpilers/transpile-set-static-attribute-to-js-lines.type';

export interface IPrimaryTranspilers extends
  //
  ITranspileApplyNodeModifiersToJSLinesTrait,
  ITranspileAttachNodeToJSLinesTrait,
  ITranspileCreateReactiveAsyncNodeToJSLinesTrait,
  ITranspileCreateReactiveCustomElementNodeToJSLinesTrait,
  ITranspileCreateReactiveElementNodeToJSLinesTrait,
  ITranspileCreateReactiveForLoopNodeToJSLinesTrait,
  ITranspileCreateReactiveIfNodeToJSLinesTrait,
  ITranspileCreateReactiveSwitchNodeToJSLinesTrait,
  ITranspileCreateReactiveTextNodeToJSLinesTrait,
  ITranspileCreateStaticTextNodeToJSLinesTrait,
  ITranspileSetReactiveAttributeToJSLinesTrait,
  ITranspileSetReactiveClassNamesListToJSLinesTrait,
  ITranspileSetReactiveClassToJSLinesTrait,
  ITranspileSetReactiveEventListenerToJSLinesTrait,
  ITranspileSetReactiveInputToJSLinesTrait,
  ITranspileSetReactiveOutputToJSLinesTrait,
  ITranspileSetReactivePropertyToJSLinesTrait,
  ITranspileSetReactiveStylePropertiesMapToJSLinesTrait,
  ITranspileSetReactiveStylePropertyToJSLinesTrait,
  ITranspileSetStaticAttributeToJSLinesTrait
//
{
}

export interface IHavingPrimaryTranspilersOptions {
  readonly transpilers: IPrimaryTranspilers;
}

