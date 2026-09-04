import { getElementTagName } from '../../../../../../../dom-manipulation/helpers/misc/get-element-tag-name';
import { indentLines } from '../../../../../../misc/lines/functions/indent-lines';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { generateTemplateVariableName } from '../../../../../../misc/templates/generate-template-variable-name';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import {
  extractRXAttributesAndLetPropertiesFromReactiveHTMLAttribute,
} from '../helpers/extract-attributes/extract-rx-attributes-and-let-properties-from-reactive-html-attribute';
import { generateJSLinesForRXTemplateFromNodes } from '../helpers/for-rx-template/generate-js-lines-for-rx-template-from-nodes';
import { generateLetPropertyLinesForTemplate } from '../helpers/for-rx-template/let-properties/generate-let-property-lines-for-template';
import { ILines } from '../../../../../../misc/lines/lines.type';
import {
  createAtLeastOneOfTheseAttributesIsRequiredError,
} from '../../../../../../misc/errors/create-at-least-one-of-these-attributes-is-required-error';

/*
Syntax:

<rx-template
  name="templateReference"
  as="name"
  export="$.$observer"
  let-var1
  let-var2
>
  ...content
</rx-template>

 */

const TAG_NAME: string = 'rx-template';

const TEMPLATE_NAME_ATTRIBUTE_NAME: string = 'name';
const TEMPLATE_AS_ATTRIBUTE_NAME: string = 'as';
const TEMPLATE_EXPORT_ATTRIBUTE_NAME: string = 'export';

const ATTRIBUTE_NAMES: Set<string> = new Set<string>([
  TEMPLATE_NAME_ATTRIBUTE_NAME,
  TEMPLATE_AS_ATTRIBUTE_NAME,
  TEMPLATE_EXPORT_ATTRIBUTE_NAME,
]);

export interface ITranspileReactiveHTMLRXTemplateToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLRXTemplateToJSLines(
  {
    node,
    ...options
  }: ITranspileReactiveHTMLRXTemplateToJSLinesOptions,
): ILinesOrNull {
  const name: string = getElementTagName(node);
  if (name === TAG_NAME) {
    const { attributes, letProperties } = extractRXAttributesAndLetPropertiesFromReactiveHTMLAttribute(
      node.attributes,
      ATTRIBUTE_NAMES,
    );

    const as: string | undefined = attributes.get(TEMPLATE_AS_ATTRIBUTE_NAME);
    const templateName: string | undefined = attributes.get(TEMPLATE_NAME_ATTRIBUTE_NAME) ?? as;

    if (templateName === void 0) {
      throw createAtLeastOneOfTheseAttributesIsRequiredError([TEMPLATE_NAME_ATTRIBUTE_NAME, TEMPLATE_AS_ATTRIBUTE_NAME], node);
    }

    const templateVariableName: string = generateTemplateVariableName(templateName);

    const lines: ILines = [
      `// template`,
      `const ${templateVariableName} = (`,
      ...indentLines(
        generateJSLinesForRXTemplateFromNodes({
          ...options,
          nodes: node.childNodes,
          argumentsLines: generateLetPropertyLinesForTemplate(letProperties),
        }),
      ),
      `);`,
    ];

    if (as !== void 0) {
      lines.push(...[
        `// as`,
        `const ${as} = ${templateVariableName};`,
      ]);
    }

    const exportTo: string | undefined = attributes.get(TEMPLATE_EXPORT_ATTRIBUTE_NAME);

    if (exportTo !== void 0) {
      lines.push(...[
        `// export template`,
        `${exportTo}(${templateVariableName});`,
      ]);
    }

    return lines;
  } else {
    return null;
  }
}


