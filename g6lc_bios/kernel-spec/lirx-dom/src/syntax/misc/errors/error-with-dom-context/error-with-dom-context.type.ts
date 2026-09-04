import { ICustomError, ICustomErrorMessageOptionalOptions } from '@lirx/utils';
import { IErrorWithDOMContextName } from './error-with-dom-context-name.constant';

export interface IErrorWithDOMContextOptions extends Required<ICustomErrorMessageOptionalOptions>, IErrorWithDOMContextProperties {
}

export interface IErrorWithDOMContextProperties {
  node: Node;
}

export type IErrorWithDOMContext = ICustomError<IErrorWithDOMContextName, IErrorWithDOMContextProperties>;

