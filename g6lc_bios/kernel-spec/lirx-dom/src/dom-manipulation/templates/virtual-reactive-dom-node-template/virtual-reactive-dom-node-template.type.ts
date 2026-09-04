import { IVirtualDOMNodeTemplate } from '../virtual-dom-node-template/virtual-dom-node-template.type';

export type IVirtualReactiveDOMNodeTemplate<GTemplateArgument extends object> = IVirtualDOMNodeTemplate<[GTemplateArgument]>;

export type IGenericVirtualReactiveDOMNodeTemplate = IVirtualReactiveDOMNodeTemplate<object>;

export type IGenericVirtualReactiveDOMNodeTemplateOrNull = IGenericVirtualReactiveDOMNodeTemplate | null;
