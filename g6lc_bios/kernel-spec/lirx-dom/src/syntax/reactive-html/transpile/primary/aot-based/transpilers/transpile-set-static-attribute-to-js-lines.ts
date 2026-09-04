import {
  IGenericVirtualElementNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-element-node/generic-virtual-element-node.type';
import {
  IAttributeWriteValue,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-element-node/members/attribute/attribute-value.type';
import {
  virtualElementNodeAppendClassName,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-element-node/members/class-name/virtual-element-node-append-class-name';
import {
  IGenericVirtualReactiveElementNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/generic-virtual-reactive-element-node.type';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileSetStaticAttributeToJSLinesFunction,
  ITranspileSetStaticAttributeToJSLinesOptions,
} from '../../transpilers/transpile-set-static-attribute-to-js-lines.type';

export const transpileAOTSetStaticAttributeToJSLines: ITranspileSetStaticAttributeToJSLinesFunction = (
  {
    node,
    name,
    value,
  }: ITranspileSetStaticAttributeToJSLinesOptions,
): ILines => {
  if (isClassAttribute(name)) {
    return inlineLastLines(
      [`aot_22(`],
      node,
      [', '],
      value,
      [');'],
    );
  } else {
    return inlineLastLines(
      [`aot_23(`],
      node,
      [', '],
      name,
      [', '],
      value,
      [');'],
    );
  }
};

export function aot_22(
  node: IGenericVirtualElementNode,
  classNames: string | readonly string[],
): void {
  return virtualElementNodeAppendClassName(
    node,
    classNames,
  );
}

export function aot_23(
  node: IGenericVirtualReactiveElementNode,
  name: string,
  value: IAttributeWriteValue,
): void {
  return node.setAttribute(
    name,
    value,
  );
}

/*---*/

function isClassAttribute(
  name: ILines,
): boolean {
  return (name[0] === '"class"');
}
