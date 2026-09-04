import { HTML_NAMESPACE_URI_CONSTANT } from '../../../../../../dom-manipulation/misc/namespace-uri/html-namespace-uri.constant';
import { MATH_ML_NAMESPACE_URI_CONSTANT } from '../../../../../../dom-manipulation/misc/namespace-uri/math-ml-namespace-uri.constant';
import { SVG_NAMESPACE_URI_CONSTANT } from '../../../../../../dom-manipulation/misc/namespace-uri/svg-namespace-uri.constant';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileCreateReactiveElementNodeToJSLinesFunction,
  ITranspileCreateReactiveElementNodeToJSLinesOptions,
} from '../../transpilers/transpile-create-reactive-element-node-to-js-lines.type';

export const transpileCreateReactiveElementNodeToJSLines: ITranspileCreateReactiveElementNodeToJSLinesFunction = (
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
        `VirtualReactiveElementNode.createHTML(${params})`,
      ];
    case SVG_NAMESPACE_URI_CONSTANT:
      return [
        `VirtualReactiveElementNode.createSVG(${params})`,
      ];
    case MATH_ML_NAMESPACE_URI_CONSTANT:
      return [
        `VirtualReactiveElementNode.createMathML(${params})`,
      ];
    default:
      return [
        `new VirtualReactiveElementNode(${JSON.stringify(namespaceURI)}, ${params})`,
      ];
  }

};


