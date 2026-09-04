import { ILines } from '../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../primary/primary-transpilers.type';
import {
  ITranspileCreateReactiveCustomElementNodeToJSLinesOptionsSlotsMap,
} from '../../../../../primary/transpilers/transpile-create-reactive-custom-element-node-to-js-lines.type';
import {
  generateJSLinesForRXTemplate,
} from '../../../../rx-component/transpilers/helpers/for-rx-template/generate-js-lines-for-rx-template';
import { DEFAULT_SLOT_NAME_CONSTANT } from './default-slot-name.constant';
import {
  transpileReactiveHTMLCustomElementChildElementToSlotsOfJSLines,
} from './transpile-reactive-html-custom-element-child-element-to-slots-of-js-lines';
import {
  transpileReactiveHTMLCustomElementChildTextToSlotsOfJSLines,
} from './transpile-reactive-html-custom-element-child-text-to-slots-of-js-lines';

export interface ITranspileReactiveHTMLCustomElementChildrenToSlotsOfJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly nodes: ArrayLike<Node>;
}

export function transpileReactiveHTMLCustomElementChildrenToSlotsOfJSLines(
  {
    nodes,
    transpilers,
  }: ITranspileReactiveHTMLCustomElementChildrenToSlotsOfJSLinesOptions,
): ITranspileCreateReactiveCustomElementNodeToJSLinesOptionsSlotsMap {
  const defaultSlotBodyLines: ILines = [];
  const slots: ITranspileCreateReactiveCustomElementNodeToJSLinesOptionsSlotsMap = new Map<string, ILines>();

  for (let i = 0; i < nodes.length; i++) {
    const node: Node = nodes[i];
    switch (node.nodeType) {
      case Node.TEXT_NODE:
        transpileReactiveHTMLCustomElementChildTextToSlotsOfJSLines({
          node: node as Text,
          defaultSlotBodyLines,
          transpilers,
        });
        break;
      case Node.COMMENT_NODE:
        break;
      case Node.ELEMENT_NODE:
        transpileReactiveHTMLCustomElementChildElementToSlotsOfJSLines({
          node: node as Element,
          defaultSlotBodyLines,
          slots,
          transpilers,
        });
        break;
      default:
        break;
    }
  }

  if (defaultSlotBodyLines.length > 0) {
    slots.set(DEFAULT_SLOT_NAME_CONSTANT, generateJSLinesForRXTemplate({
      argumentsLines: null,
      bodyLines: defaultSlotBodyLines,
    }));
  }

  // deleteEmptySlots(slots);

  return slots;
}

