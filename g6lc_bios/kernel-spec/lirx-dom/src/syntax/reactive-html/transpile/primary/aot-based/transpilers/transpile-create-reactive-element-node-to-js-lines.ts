import { HTML_NAMESPACE_URI_CONSTANT } from '../../../../../../dom-manipulation/misc/namespace-uri/html-namespace-uri.constant';
import { MATH_ML_NAMESPACE_URI_CONSTANT } from '../../../../../../dom-manipulation/misc/namespace-uri/math-ml-namespace-uri.constant';
import { SVG_NAMESPACE_URI_CONSTANT } from '../../../../../../dom-manipulation/misc/namespace-uri/svg-namespace-uri.constant';
import {
  VirtualReactiveElementNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/virtual-reactive-element-node.class';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileCreateReactiveElementNodeToJSLinesFunction,
  ITranspileCreateReactiveElementNodeToJSLinesOptions,
} from '../../transpilers/transpile-create-reactive-element-node-to-js-lines.type';

export const transpileAOTCreateReactiveElementNodeToJSLines: ITranspileCreateReactiveElementNodeToJSLinesFunction = (
  {
    namespaceURI,
    name,
    options,
  }: ITranspileCreateReactiveElementNodeToJSLinesOptions,
): ILines => {
  const params: string = `${JSON.stringify(name)}${(options === void 0) ? '' : `, ${JSON.stringify(options)}`}`;

  switch (namespaceURI) {
    case HTML_NAMESPACE_URI_CONSTANT:
      return [
        `aot_2(${params})`,
      ];
    case SVG_NAMESPACE_URI_CONSTANT:
      return [
        `aot_3(${params})`,
      ];
    case MATH_ML_NAMESPACE_URI_CONSTANT:
      return [
        `aot_4(${params})`,
      ];
    default:
      return [
        `aot_5(${JSON.stringify(namespaceURI)}, ${params})`,
      ];
  }

};

export function aot_2(
  name: string,
  options?: ElementCreationOptions,
): VirtualReactiveElementNode<HTMLElement> {
  return VirtualReactiveElementNode.createHTML(
    name,
    options,
  );
}

export function aot_3(
  name: string,
  options?: ElementCreationOptions,
): VirtualReactiveElementNode<SVGElement> {
  return VirtualReactiveElementNode.createSVG(
    name,
    options,
  );
}

export function aot_4(
  name: string,
  options?: ElementCreationOptions,
): VirtualReactiveElementNode<MathMLElement> {
  return VirtualReactiveElementNode.createMathML(
    name,
    options,
  );
}

export function aot_5(
  nnamespaceURI: string,
  name: string,
  options?: ElementCreationOptions,
): VirtualReactiveElementNode<MathMLElement> {
  return new VirtualReactiveElementNode(
    nnamespaceURI,
    name,
    options,
  );
}
