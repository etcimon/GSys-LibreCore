import { startEnd, wrap } from './helpers';

export const XMLNameStartChar: string = '[' +
  ':' + '_' + 'a-z' + 'A-Z' +
  '\\u00c0-\\u00d6' + '\\u00d8-\\u00f6' + '\\u00f8-\\u02ff' + '\\u0370-\\u037d' +
  '\\u037f-\\u1fff' + '\\u200c-\\u200d' + '\\u2070-\\u218f' +
  '\\u2c00-\\u2fef' + '\\u3001-\\ud7ff' + '\\uf900-\\ufdcf' +
  '\\ufdf0-\\ufffd' +
  ']';

export const XMLNameChar: string = wrap(XMLNameStartChar + '|' + '[' +
  '\\-' + '\\.' + '0-9' + '\\u00b7' + '\\u0300-\\u036f' + '\\u203f-\\u2040' +
  ']');

export const XMLName: string = wrap(XMLNameStartChar + XMLNameChar + '*');
export const XMLNameRegExp = new RegExp(startEnd(XMLName));

export function isValidXMLName(input: string): boolean {
  return XMLNameRegExp.test(input);
}


