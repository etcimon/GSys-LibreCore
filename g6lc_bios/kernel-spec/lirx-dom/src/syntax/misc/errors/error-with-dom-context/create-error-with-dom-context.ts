import { createCustomError } from '@lirx/utils';
import { nodeToHTML } from '../../dom-node-to-html/node-to-html';
import { linesToString } from '../../lines/functions/lines-to-string';
import { ILines } from '../../lines/lines.type';
import { ERROR_WITH_DOM_CONTEXT_NAME, IErrorWithDOMContextName } from './error-with-dom-context-name.constant';
import { IErrorWithDOMContext, IErrorWithDOMContextOptions, IErrorWithDOMContextProperties } from './error-with-dom-context.type';

export function createErrorWithDOMContext(
  {
    message,
    node,
    ...options
  }: IErrorWithDOMContextOptions,
): IErrorWithDOMContext {
  return createCustomError<IErrorWithDOMContextName, IErrorWithDOMContextProperties>({
    name: ERROR_WITH_DOM_CONTEXT_NAME,
    message: generateErrorWithDOMContextMessage(message, node),
    node,
    ...options,
  });
}

/*----*/

function generateErrorWithDOMContextMessage(
  message: string,
  node: Node,
): string {
  return linesToString(generateErrorWithDOMContextMessageLines(message, node));
}

function generateErrorWithDOMContextMessageLines(
  message: string,
  node: Node,
): ILines {
  const stack: ILines = ((node.nodeType === Node.ATTRIBUTE_NODE) && ((node as Attr).ownerElement !== null))
    ? nodeToHTML((node as Attr).ownerElement!)
    : nodeToHTML(node);

  return [
    message,
    '',
    ...stack,
    '',
  ];
}



