import { inlineLastLines } from '../../../../../../../misc/lines/functions/after-last-line';
import { wrapLinesWithCurlyBrackets } from '../../../../../../../misc/lines/functions/wrap-lines-with-curly-brackets';
import { ILinesOrNull } from '../../../../../../../misc/lines/lines-or-null.type';
import {
  ICreateOnCommandFunctionForTemplateWithoutAttributesGetArgumentsLinesFunctionOptions,
} from '../../helpers/for-rx-template/built-in/without-attributes/create-on-command-function-for-template-without-attributes';
import {
  createOnFunctionsForTemplateWithoutAttributes,
  ICreateOnFunctionsForTemplateWithoutAttributes,
  ICreateOnFunctionsForTemplateWithoutAttributesResult,
} from '../../helpers/for-rx-template/built-in/without-attributes/create-on-functions-for-template-without-attributes';
import {
  ICreateOnTagFunctionForTemplateWithoutAttributesGetArgumentsLinesFunctionOptions,
} from '../../helpers/for-rx-template/built-in/without-attributes/create-on-tag-function-for-template-without-attributes';

const LET_VALUE_ATTRIBUTE_NAME: string = 'let-value';

export function getOnFunctionsForRXAsyncChild(
  {
    tag,
    command,
  }: ICreateOnFunctionsForTemplateWithoutAttributes,
): ICreateOnFunctionsForTemplateWithoutAttributesResult {
  return createOnFunctionsForTemplateWithoutAttributes({
    tag: {
      ...tag,
      extraAttributes: [LET_VALUE_ATTRIBUTE_NAME],
      getArgumentsLines: getTagTemplateArgumentsLinesForRXAsyncChild,
    },
    command: {
      ...command,
      getArgumentsLines: getCommandTemplateArgumentsLinesForRXAsyncChild,
    },
  });
}

/* FUNCTIONS */

function getTagTemplateArgumentsLinesForRXAsyncChild(
  {
    node,
    attributes,
  }: ICreateOnTagFunctionForTemplateWithoutAttributesGetArgumentsLinesFunctionOptions,
): ILinesOrNull {
  const letValueAttribute: string | undefined = attributes.get(LET_VALUE_ATTRIBUTE_NAME);
  return (letValueAttribute === void 0)
    ? null
    : getCommandTemplateArgumentsLinesForRXAsyncChild({
      node,
      attributeValue: (
        (letValueAttribute === '')
          ? 'value'
          : letValueAttribute
      ),
    });
}

function getCommandTemplateArgumentsLinesForRXAsyncChild(
  {
    attributeValue,
  }: ICreateOnCommandFunctionForTemplateWithoutAttributesGetArgumentsLinesFunctionOptions,
): ILinesOrNull {
  return (attributeValue === '')
    ? null
    : inlineLastLines(
      wrapLinesWithCurlyBrackets(
        [
          (attributeValue === 'value')
            ? 'value,'
            : `value: ${attributeValue},`,
        ],
        false,
      ),
      [','],
    );
}
