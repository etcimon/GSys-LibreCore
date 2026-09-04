import { startEnd, wrap } from './helpers';

/**
 * CSS: https://www.w3.org/TR/CSS21/grammar.html#scanner
 */

export const CSSHex: string = '[0-9a-f]'; // [0-9a-f]
export const CSSNonASCII: string = '[\\u00a0-\\u{10ffff}]';
export const CSSUnicode: string = wrap('\\\\' + CSSHex + '{1,6}(\\r\\n|[ \\t\\r\\n\\f])?'); // \\{h}{1,6}(\r\n|[ \t\r\n\f])?
export const CSSEscape: string = wrap(CSSUnicode + '|' + '\\\\[^\\r\\n\\f0-9a-f]'); // {unicode}|\\[^\r\n\f0-9a-f]
export const CSSNMStart: string = wrap('[_a-z]' + '|' + CSSNonASCII + '|' + CSSEscape); // [_a-z]|{nonascii}|{escape}
export const CSSNMChar: string = wrap('[_a-z0-9-]' + '|' + CSSNonASCII + '|' + CSSEscape); // [_a-z0-9-]|{nonascii}|{escape}
export const CSSIdent: string = '-?' + CSSNMStart + CSSNMChar + '*';

export const CSSIdentifierRegExp = new RegExp(startEnd(CSSIdent), 'u');

export function isValidCSSIdentifier(input: string): boolean {
  return CSSIdentifierRegExp.test(input);
}


