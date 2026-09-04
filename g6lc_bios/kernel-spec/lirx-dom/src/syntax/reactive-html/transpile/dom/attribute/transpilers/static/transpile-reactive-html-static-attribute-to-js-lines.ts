import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';

export interface ITranspileReactiveHTMLStaticAttributeToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly attribute: Attr;
}

export function transpileReactiveHTMLStaticAttributeToJSLines(
  {
    attribute,
    transpilers,
  }: ITranspileReactiveHTMLStaticAttributeToJSLinesOptions,
): ILinesOrNull {
  const {
    transpileSetStaticAttributeToJSLines,
  } = transpilers;
  return (attribute.name === 'is')
    ? null
    : [
      `// static attribute '${attribute.name}'`,
      ...transpileSetStaticAttributeToJSLines({
        node: ['node'],
        name: [JSON.stringify(attribute.name)],
        value: [JSON.stringify(attribute.value)],
      }),
    ];
}

