import { ILinesOrNull } from '../../../misc/lines/lines-or-null.type';
import { transpileReactiveHTMLNodesToJSLines } from '../dom/nodes/transpile-reactive-html-nodes-to-js-lines';
import { IHavingPrimaryTranspilersOptions } from '../primary/primary-transpilers.type';

export interface ITranspileReactiveHTMLToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly html: string;
}

export function transpileReactiveHTMLToJSLines(
  {
    html,
    ...options
  }: ITranspileReactiveHTMLToJSLinesOptions,
): ILinesOrNull {

  const document: Document = new DOMParser()
    .parseFromString(
      `<!DOCTYPE html><html><body>${html}</body></html>`,
      'text/html',
    );
  // .parseFromString(
  //   // html,
  //   `
  //     <!DOCTYPE html>
  //     <html>
  //       <head></head>
  //       <body>${html}</body>
  //     </html>
  //     `,
  //   'text/html',
  //   // 'application/xhtml+xml'
  // );
  return transpileReactiveHTMLNodesToJSLines({
    ...options,
    nodes: document.body.childNodes,
  });
}
