import { getElementTagName } from '../../../../../../../dom-manipulation/helpers/misc/get-element-tag-name';
import { throwIfHasChildNodes } from '../../../../../../../dom-manipulation/helpers/misc/throw-if-has-child-nodes';
import { createMissingAttributeError } from '../../../../../../misc/errors/create-missing-attribute-error';
import { indentLines } from '../../../../../../misc/lines/functions/indent-lines';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../misc/lines/lines.type';
import { generateTemplateVariableName } from '../../../../../../misc/templates/generate-template-variable-name';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import {
  extractRXAttributesAndLetPropertiesFromReactiveHTMLAttribute,
} from '../helpers/extract-attributes/extract-rx-attributes-and-let-properties-from-reactive-html-attribute';
import {
  generateLetPropertyLinesForInjectTemplate,
} from '../helpers/for-rx-template/let-properties/generate-let-property-lines-for-inject-template';

/*
Syntax:

<rx-inject-template
  template="templateReference"
  let-var1="data1"
  let-var2="data2"
></rx-inject-template>

 */

const TAG_NAME: string = 'rx-inject-template';

const TEMPLATE_ATTRIBUTE_NAME: string = 'template';

const ATTRIBUTE_NAMES: Set<string> = new Set<string>([
  TEMPLATE_ATTRIBUTE_NAME,
]);

export interface ITranspileReactiveHTMLRXInjectTemplateToLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLRXInjectTemplateToLines(
  {
    node,
    ...options
  }: ITranspileReactiveHTMLRXInjectTemplateToLinesOptions,
): ILinesOrNull {
  const name: string = getElementTagName(node);
  if (name === TAG_NAME) {
    const { attributes, letProperties } = extractRXAttributesAndLetPropertiesFromReactiveHTMLAttribute(
      node.attributes,
      ATTRIBUTE_NAMES,
    );

    const templateName: string | undefined = attributes.get(TEMPLATE_ATTRIBUTE_NAME);

    if (templateName === void 0) {
      throw createMissingAttributeError(TEMPLATE_ATTRIBUTE_NAME, node);
    }

    throwIfHasChildNodes(node);

    const letPropertiesLines: ILines = generateLetPropertyLinesForInjectTemplate(letProperties, node);

    return [
      `// inject template`,
      `${generateTemplateVariableName(templateName)}(`,
      ...indentLines([
        `parentNode,`,
        ...letPropertiesLines,
      ]),
      `);`,
    ];
  } else {
    return null;
  }
}

