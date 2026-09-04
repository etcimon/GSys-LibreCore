import { throwIfHasChildNodes } from '../../../../../../../dom-manipulation/helpers/misc/throw-if-has-child-nodes';
import { createInvalidForLoopSyntaxError } from '../../../../../../misc/errors/create-invalid-for-loop-syntax-error';
import { createMissingAttributeError } from '../../../../../../misc/errors/create-missing-attribute-error';
import { wrapLinesWithCurlyBrackets } from '../../../../../../misc/lines/functions/wrap-lines-with-curly-brackets';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../misc/lines/lines.type';
import { generateTemplateVariableName } from '../../../../../../misc/templates/generate-template-variable-name';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import {
  extractRXAttributesFromReactiveHTMLAttribute,
} from '../helpers/extract-attributes/extract-rx-attributes-from-reactive-html-attribute';
import { IMappedAttributes } from '../helpers/extract-attributes/mapped-attributes.type';
import {
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunction,
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunctionOptions,
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunction,
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunctionOptions,
  transpileReactiveHTMLRXChildTemplateToJSLines,
} from '../helpers/for-rx-template/transpile-reactive-html-rx-child-template-to-js-lines';
import { extractRXForLoopCommand, IRXForLoopCommand } from './extract-rx-for-loop-command';
import { generateJSLinesForRXForLoop } from './generate-js-lines-for-rx-for-loop';
import { extractReactiveValueFromString } from '../../../../misc/extract-reactive-value-from-string';

/*
Syntax:

<rx-for-loop
  items="itemsObservable"
  template="templateReference"
  track-by="trackByFunction"
></rx-for-loop>

 */

/*
Syntax - alternative:

<element
  *for="let item of items; index as index; trackBy: trackByFn"
>
  ...content
</element>

====> equivalent

<rx-template
  name="uuid"
>
  ...content
</rx-template>
<rx-for-loop
  items="items"
  template="uuid"
  track-by="trackByFn"
></rx-for-loop>

 */

const TAG_NAME: string = 'rx-for-loop';
const COMMAND_NAME: string = '*for';

const ITEMS_ATTRIBUTE_NAME: string = 'items';
const TEMPLATE_ATTRIBUTE_NAME: string = 'template';
const TRACK_BY_ATTRIBUTE_NAME: string = 'track-by';

const ATTRIBUTE_NAMES: Set<string> = new Set<string>([
  ITEMS_ATTRIBUTE_NAME,
  TEMPLATE_ATTRIBUTE_NAME,
  TRACK_BY_ATTRIBUTE_NAME,
]);

export interface ITranspileReactiveHTMLRXForLoopToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLRXForLoopToJSLines(
  options: ITranspileReactiveHTMLRXForLoopToJSLinesOptions,
): ILinesOrNull {
  return transpileReactiveHTMLRXChildTemplateToJSLines({
    ...options,
    tagName: TAG_NAME,
    commandName: COMMAND_NAME,
    onTag: getOnTagFunctionForRXForLoop(options),
    onCommand: getOnCommandFunctionForRXForLoop(options),
  });
}

/* FUNCTIONS */

/* TEMPLATE */

function getOnTagFunctionForRXForLoop(
  options: ITranspileReactiveHTMLRXForLoopToJSLinesOptions,
): ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunction {
  return (
    {
      node,
      generateTemplate,
    }: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunctionOptions,
  ): ILinesOrNull => {
    let items!: string;
    let template!: ILines;
    let trackBy!: string | undefined;

    const attributes: IMappedAttributes = extractRXAttributesFromReactiveHTMLAttribute(
      node.attributes,
      ATTRIBUTE_NAMES,
    );

    /* ITEMS */
    const itemsAttribute: string | undefined = attributes.get(ITEMS_ATTRIBUTE_NAME);

    if (itemsAttribute === void 0) {
      throw createMissingAttributeError(ITEMS_ATTRIBUTE_NAME, node);
    } else {
      items = itemsAttribute;
    }

    /* TEMPLATE */
    const templateAttribute: string | undefined = attributes.get(TEMPLATE_ATTRIBUTE_NAME);

    if (templateAttribute === void 0) {
      const properties: string[] = [
        `item`,
        `index$`,
      ];
      template = generateTemplate({
        argumentsLines: wrapLinesWithCurlyBrackets(properties.map(_ => `${_},`), false),
      });
    } else {
      template = [generateTemplateVariableName(templateAttribute)];
      throwIfHasChildNodes(node);
    }

    /* TRACK BY */
    const trackByAttribute: string | undefined = attributes.get(TRACK_BY_ATTRIBUTE_NAME);

    if (trackByAttribute === void 0) {
      trackBy = void 0;
    } else {
      trackBy = itemsAttribute;
    }

    return generateJSLinesForRXForLoop({
      ...options,
      items: extractReactiveValueFromString(items),
      template,
      trackBy,
    });
  };
}

/* COMMAND */

function getOnCommandFunctionForRXForLoop(
  options: ITranspileReactiveHTMLRXForLoopToJSLinesOptions,
): ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunction {
  return (
    {
      node,
      attributeValue,
      generateTemplate,
    }: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunctionOptions,
  ): ILinesOrNull => {
    let command: IRXForLoopCommand;
    try {
      command = extractRXForLoopCommand(attributeValue);
    } catch (error: unknown) {
      throw (error instanceof Error)
        ? createInvalidForLoopSyntaxError(error.message, node)
        : error;
    }

    node.removeAttribute(COMMAND_NAME);

    const templateVariablesLines: ILines = [
      (command.item === 'item')
        ? `item,`
        : `item: ${command.item},`,
    ];

    if (command.index !== void 0) {
      templateVariablesLines.push(
        (command.index === 'index$')
          ? `index$,`
          : `index$: ${command.index},`,
      );
    }

    return generateJSLinesForRXForLoop(
      {
        ...options,
        items: command.items,
        template: generateTemplate({
          argumentsLines: wrapLinesWithCurlyBrackets(templateVariablesLines, false),
        }),
        trackBy: command.trackBy,
      },
    );
  };
}


